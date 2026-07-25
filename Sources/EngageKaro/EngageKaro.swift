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
        self.config = config
        consentGiven = !config.requireConsent
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

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let data = notification.request.content.userInfo
        if let id = data["ek_message_id"] as? String {
            await reportPushReceipt(messageId: id, event: "delivered", properties: data as? [String: Any])
        }
        // An app that had its own delegate may want different presentation options;
        // defer to it when it has an opinion.
        if let prev = previousNotificationDelegate,
           let options = await prev.userNotificationCenter?(center, willPresent: notification) {
            return options
        }
        return [.banner, .sound, .badge]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
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

        // Let the app's own delegate see the tap too.
        await previousNotificationDelegate?.userNotificationCenter?(center, didReceive: response)
    }

    /// `ek_url` as a URL, if the payload carries a usable one.
    private func deepLinkURL(from payload: [String: Any]) -> URL? {
        guard let raw = payload["ek_url"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }
}
