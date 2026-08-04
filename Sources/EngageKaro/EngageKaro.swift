import Foundation
import UIKit
import UserNotifications

/// EngageKaro iOS SDK — direct APNs (no Firebase on iOS).
///
/// ```swift
/// EngageKaro.shared.initialize(EngageKaroConfig(
///     appId: "...", apiKey: "ek_client_...", baseUrl: "https://api.host"
/// ))
/// await EngageKaro.shared.login(externalId: "user-123")
/// await EngageKaro.shared.requestPushPermission()
/// ```
@MainActor
public final class EngageKaro: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = EngageKaro()

    private var config: EngageKaroConfig?
    private var externalId: String?
    private var consentGiven = true
    private var pendingPushToken: String?
    private var currentToken: String?
    private let sessions = SessionTracker()
    private var foregroundObserver: NSObjectProtocol?

    /// Invoked when the user taps a notification, with the full APNs payload —
    /// your custom `data` keys plus EngageKaro's own `ek_*` keys.
    ///
    /// Set this to route taps yourself:
    /// ```swift
    /// EngageKaro.shared.onNotificationOpened = { payload in
    ///     if let target = payload["targetId"] as? String { router.open(target) }
    /// }
    /// ```
    /// If you leave it nil, the SDK opens `ek_url` (the campaign's deep link)
    /// itself. Registering a handler suppresses that — routing becomes yours,
    /// including the deep link, available as `payload["ek_url"]`.
    ///
    /// A tap that lands before this is set (a cold launch from a notification)
    /// is buffered and replayed on assignment, so it is never dropped.
    public var onNotificationOpened: (([String: Any]) -> Void)? {
        didSet {
            guard let handler = onNotificationOpened, let buffered = pendingOpened else { return }
            pendingOpened = nil
            handler(buffered)
        }
    }

    private var pendingOpened: [String: Any]?
    /// Whatever delegate was installed before us, so we don't silently break it.
    private weak var previousNotificationDelegate: UNUserNotificationCenterDelegate?

    public var isInitialized: Bool { config != nil }

    private var canSend: Bool {
        guard isInitialized else { return false }
        return !(config?.requireConsent == true && !consentGiven)
    }

    private override init() {
        super.init()
        externalId = UserDefaults.standard.string(forKey: "engagekaro_external_id")
    }

    /// Call once at app launch (e.g. AppDelegate / @main App init).
    public func initialize(_ config: EngageKaroConfig) {
        setupCore(config)
        // Take over the delegate, but keep a reference to the incumbent and forward
        // to it — apps commonly set their own in AppDelegate, and silently dropping
        // it would break their existing notification handling.
        let existing = UNUserNotificationCenter.current().delegate
        if existing !== self { previousNotificationDelegate = existing }
        UNUserNotificationCenter.current().delegate = self
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.onForeground() }
        }
        Task { await onForeground() }
    }

    /// The state [initialize] sets up, minus delegate/foreground-observer
    /// installation. Used directly by [persistBridgeConfig]: wrapper SDKs
    /// (Flutter, React Native) install their own `UNUserNotificationCenterDelegate`
    /// and own their own foreground/session timing on the Dart/JS side, so running
    /// this class's copy too would double-dispatch taps. See
    /// sdk-native-wrapper-design.md.
    private func setupCore(_ config: EngageKaroConfig) {
        self.config = config
        consentGiven = !config.requireConsent
    }

    private func pushPermissionLabel() async -> String? {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "granted"
        case .denied: return "denied"
        default: return "unknown"
        }
    }

    private func pingDeviceContext(sessionStart: Bool = false) async {
        guard canSend, let config, externalId != nil else { return }
        do {
            let countSession = sessionStart && sessions.noteForeground()
            let permission = await pushPermissionLabel()
            try await ApiClient.identify(
                config: config,
                externalId: externalId,
                deviceContext: DeviceContext.collect(sessionStart: countSession, pushPermission: permission)
            )
        } catch {
            // Best-effort device profile sync.
        }
    }

    private func runPostLoginTasks() async {
        guard canSend else { return }
        if let token = pendingPushToken ?? currentToken {
            try? await registerPushToken(token)
        }
        await pingDeviceContext(sessionStart: true)
    }

    public func onForeground() async {
        try? await pingDeviceContext(sessionStart: true)
        // Drain anything queued while the device was offline.
        if let config { await OfflineQueue.flush(config: config) }
    }

    public func login(externalId: String, identityHash: String? = nil) async throws {
        self.externalId = externalId
        ApiClient.identityHash = identityHash
        UserDefaults.standard.set(externalId, forKey: "engagekaro_external_id")
        guard canSend else { return }
        Task { await runPostLoginTasks() }
    }

    public func logout() {
        externalId = nil
        ApiClient.identityHash = nil
        UserDefaults.standard.removeObject(forKey: "engagekaro_external_id")
    }

    public func trackEvent(_ name: String, properties: [String: Any]? = nil) async throws {
        guard canSend, let config else { return }
        try await ApiClient.track(config: config, name: name, externalId: externalId, properties: properties)
    }

    public func addTag(_ key: String, value: Any) async throws {
        try await addTags([key: value])
    }

    public func addTags(_ tags: [String: Any?]) async throws {
        guard canSend, let config, let externalId else {
            throw NSError(domain: "EngageKaro", code: 1, userInfo: [NSLocalizedDescriptionKey: "Call login() first"])
        }
        try await ApiClient.updateTags(config: config, externalId: externalId, tags: tags)
    }

    public func requestPushPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                await UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            return false
        }
    }

    /// Call from AppDelegate `didRegisterForRemoteNotificationsWithDeviceToken`.
    public func setDeviceToken(_ deviceToken: Data) async throws {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        currentToken = token
        try await registerPushToken(token)
    }

    public func registerPushToken(_ token: String) async throws {
        guard canSend, let config else { return }
        guard let externalId else {
            pendingPushToken = token
            return
        }
        try await ApiClient.addSubscription(
            config: config,
            externalId: externalId,
            type: .iosPush,
            token: token
        )
        pendingPushToken = nil
    }

    /// Persist config for the Notification Service Extension (App Group).
    public func shareConfig(appGroup: String, apiBase: String, apiKey: String, externalId: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(apiBase, forKey: "ek_api_base")
        defaults.set(apiKey, forKey: "ek_api_key")
        defaults.set(externalId, forKey: "ek_external_id")
    }

    /// The same device/locale snapshot the SDK sends on `identify` calls,
    /// exposed for wrapper SDKs so they don't need to reimplement it.
    public static func deviceContextSnapshot(pushPermission: String? = nil) -> [String: Any] {
        DeviceContext.collect(pushPermission: pushPermission)
    }

    public func reportPushReceipt(messageId: String, event: String, properties: [String: Any]? = nil) async {
        guard canSend, let config else { return }
        try? await ApiClient.reportReceipt(
            config: config,
            messageId: messageId,
            event: event,
            externalId: externalId,
            properties: properties
        )
    }

    // MARK: - Cross-platform wrapper support: raw API pass-through
    //
    // Phase 2 of the wrapper refactor (see sdk-native-wrapper-design.md §4.5):
    // sdks/flutter and sdks/react-native used to ship their own HTTP clients and
    // offline queues in Dart/JS. `trackEvent`/`addTags`/`reportPushReceipt` above
    // are already safe to call directly from a wrapper (no `initialize()`-only side
    // effects), so those are reused as-is; `identify` and a generic
    // `addSubscription` have no existing public equivalent, so those two are new
    // here. Requires `persistBridgeConfig` to have run first.

    /// Mirrors sdks/android's `EngageKaro.persistBridgeConfig`. Sets up just enough
    /// state (`config`, `externalId`, identity hash) for the bridge pass-through
    /// methods to work, without installing a delegate/foreground observer — the
    /// wrapper already has its own. Safe to call repeatedly, e.g. once at wrapper
    /// `initialize()` (`externalId` nil) and again at `login()` (`externalId` set).
    /// Deliberately separate from `shareConfig(appGroup:...)` above — that method's
    /// job (NSE App-Group `UserDefaults`) is unrelated.
    public func persistBridgeConfig(apiKey: String, baseUrl: String, externalId: String? = nil, identityHash: String? = nil) {
        if !isInitialized {
            setupCore(EngageKaroConfig(appId: "", apiKey: apiKey, baseUrl: baseUrl))
        }
        if let externalId {
            self.externalId = externalId
            UserDefaults.standard.set(externalId, forKey: "engagekaro_external_id")
        }
        if let identityHash {
            ApiClient.identityHash = identityHash
        }
    }

    /// Clears the identity `persistBridgeConfig` set — call from a wrapper's
    /// `logout()`. `persistBridgeConfig` only ever *sets* `externalId` (so a
    /// repeated call can't accidentally wipe it); this is the explicit clear path.
    public func clearBridgeIdentity() {
        externalId = nil
        ApiClient.identityHash = nil
        UserDefaults.standard.removeObject(forKey: "engagekaro_external_id")
    }

    /// Raw identify call — the wrapper's own device-context snapshot goes in `deviceContext`.
    public func bridgeIdentify(deviceContext: [String: Any]? = nil) async throws {
        guard canSend, let config else { return }
        try await ApiClient.identify(config: config, externalId: externalId, deviceContext: deviceContext)
    }

    /// Generic channel subscription (push token, email, SMS) for the current user.
    public func bridgeAddSubscription(type: SubscriptionType, token: String) async throws {
        guard canSend, let config, let externalId else { return }
        try await ApiClient.addSubscription(config: config, externalId: externalId, type: type, token: token)
    }

    /// Drains anything the offline queue accumulated. Safe to call repeatedly.
    public func bridgeFlushQueue() async {
        guard let config else { return }
        await OfflineQueue.flush(config: config)
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Completion-handler form, NOT `async` — same swift-frontend IRGen crash
    // class as userNotificationCenter(_:didReceive:) below, just for this
    // method's signature/types instead. See the comment there for the full
    // explanation.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task {
            let data = notification.request.content.userInfo
            if let id = data["ek_message_id"] as? String {
                await reportPushReceipt(messageId: id, event: "delivered", properties: data as? [String: Any])
            }
            // An app that had its own delegate may want different presentation
            // options; defer to it when it has an opinion. `responds(to:)` first,
            // rather than relying on the optional-chained call to no-op safely —
            // if we handed `completionHandler` straight to a `prev?.method(...)`
            // that turns out to be unimplemented, nothing would ever call it.
            let selector = #selector(
                UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)
            )
            if let prev = previousNotificationDelegate, prev.responds(to: selector) {
                prev.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            } else {
                completionHandler([.banner, .sound, .badge])
            }
        }
    }

    // Completion-handler form, NOT `async` — Swift 6.2.3's IRGen crashes
    // synthesizing the @objc bridging thunk for this specific delegate method
    // (userNotificationCenter(_:didReceive:)) whenever an async form of its
    // signature is used, on EITHER side: as this method's own declaration, or in
    // a call to `previousNotificationDelegate`'s async overload. (Crash signature:
    // reabstraction thunk mangled name mentioning UNNotificationResponse — a real
    // swift-frontend bug, not anything about this method's logic. willPresent
    // above uses a different signature/types and isn't affected.) Both sides
    // below stick to the completion-handler form to avoid the thunk entirely.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task {
            let data = response.notification.request.content.userInfo
            if let id = data["ek_message_id"] as? String {
                await reportPushReceipt(messageId: id, event: "opened", properties: data as? [String: Any])
            }

            let payload = (data as? [String: Any]) ?? [:]
            if let handler = onNotificationOpened {
                handler(payload)
            } else if let url = deepLinkURL(from: payload) {
                // No handler registered — open the campaign's deep link ourselves so
                // links work with zero integration code.
                _ = await UIApplication.shared.open(url)
            } else {
                // Nothing to act on yet. A cold launch runs this before the app has had
                // a chance to set onNotificationOpened, so hold the payload and replay
                // it if a handler shows up.
                pendingOpened = payload
            }

            // Let the app's own delegate see the tap too. Fire-and-forget: we don't
            // need to wait for it before calling our own completion handler.
            previousNotificationDelegate?.userNotificationCenter?(
                center, didReceive: response, withCompletionHandler: {}
            )

            completionHandler()
        }
    }

    /// `ek_url` as a URL, if the payload carries a usable one.
    private func deepLinkURL(from payload: [String: Any]) -> URL? {
        guard let raw = payload["ek_url"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }
}
