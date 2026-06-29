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
    }
}
