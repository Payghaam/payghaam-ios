import Foundation

public struct PayghaamConfig: Sendable {
    public let appId: String
    public let apiKey: String
    public let baseUrl: String
    public let requireConsent: Bool
    public let timeout: TimeInterval

    public init(
        appId: String,
        apiKey: String,
        baseUrl: String,
        requireConsent: Bool = false,
        timeout: TimeInterval = 15
    ) {
        self.appId = appId
        self.apiKey = apiKey
        self.baseUrl = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.requireConsent = requireConsent
        self.timeout = timeout
    }

    var apiRoot: String { "\(baseUrl)/api/sdk" }
}

public enum SubscriptionType: String, Sendable {
    case androidPush = "ANDROID_PUSH"
    case iosPush = "IOS_PUSH"
    case webPush = "WEB_PUSH"
    case email = "EMAIL"
    case sms = "SMS"
    /// Live Activity push-to-start token (iOS 17.2+). One per app install and
    /// shared across every ActivityAttributes type, so it behaves like an
    /// ordinary device endpoint — unlike the per-activity update tokens, which
    /// are registered through `registerLiveActivityToken` instead.
    case iosLiveActivityStart = "IOS_LIVE_ACTIVITY_START"
}

public struct PayghaamApiError: Error, LocalizedError {
    public let statusCode: Int
    public let body: String
    public var errorDescription: String? { "PayghaamApiError(\(statusCode)): \(body)" }
}

enum ApiClient {
    static var identityHash: String?

    static func identify(
        config: PayghaamConfig,
        externalId: String?,
        deviceContext: [String: Any]? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let externalId { body["externalId"] = externalId }
        deviceContext?.forEach { body[$0.key] = $0.value }
        try await post(config: config, path: "/users", body: body)
    }

    static func addSubscription(
        config: PayghaamConfig,
        externalId: String,
        type: SubscriptionType,
        token: String
    ) async throws {
        try await post(config: config, path: "/users/\(externalId)/subscriptions", body: [
            "type": type.rawValue,
            "token": token,
        ])
    }

    /// Report a per-activity Live Activity update token.
    ///
    /// Distinct from `addSubscription`: this token addresses one running
    /// activity rather than the device, and it rotates over that activity's
    /// life, so it is re-posted rather than registered once.
    static func registerLiveActivityToken(
        config: PayghaamConfig,
        externalId: String,
        activityId: String,
        token: String,
        attributesType: String?
    ) async throws {
        var body: [String: Any] = [
            "externalId": externalId,
            "activityId": activityId,
            "token": token,
        ]
        if let attributesType { body["attributesType"] = attributesType }
        try await post(config: config, path: "/live-activities/tokens", body: body)
    }

    static func updateTags(config: PayghaamConfig, externalId: String, tags: [String: Any?]) async throws {
        try await put(config: config, path: "/users/\(externalId)/tags", body: ["tags": tags])
    }

    static func track(
        config: PayghaamConfig,
        name: String,
        externalId: String?,
        properties: [String: Any]?
    ) async throws {
        var body: [String: Any] = ["name": name]
        if let externalId { body["externalId"] = externalId }
        if let properties { body["properties"] = properties }
        try await post(config: config, path: "/events", body: body)
    }

    static func reportReceipt(
        config: PayghaamConfig,
        messageId: String,
        event: String,
        externalId: String?,
        properties: [String: Any]?
    ) async throws {
        var body: [String: Any] = ["messageId": messageId, "event": event]
        if let externalId { body["externalId"] = externalId }
        if let properties { body["properties"] = properties }
        try await post(config: config, path: "/receipts", body: body)
    }

    // Fire-and-forget path: send now, or park in the offline queue on a
    // retryable failure so offline activity isn't lost.
    private static func post(config: PayghaamConfig, path: String, body: [String: Any]) async throws {
        try await sendOrQueue(config: config, method: "POST", path: path, body: body)
    }

    private static func put(config: PayghaamConfig, path: String, body: [String: Any]) async throws {
        try await sendOrQueue(config: config, method: "PUT", path: path, body: body)
    }

    private static func sendOrQueue(
        config: PayghaamConfig,
        method: String,
        path: String,
        body: [String: Any]
    ) async throws {
        do {
            try await request(config: config, method: method, path: path, body: body)
            await OfflineQueue.flush(config: config)
        } catch {
            guard OfflineQueue.isRetryable(error) else { throw error }
            OfflineQueue.enqueue(method: method, path: path, body: body)
        }
    }

    /// Direct request without queueing — used by OfflineQueue's drain.
    static func rawRequest(
        config: PayghaamConfig,
        method: String,
        path: String,
        body: [String: Any]
    ) async throws {
        try await request(config: config, method: method, path: path, body: body)
    }

    private static func request(
        config: PayghaamConfig,
        method: String,
        path: String,
        body: [String: Any]
    ) async throws {
        guard let url = URL(string: config.apiRoot + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: config.timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        if let hash = identityHash {
            req.setValue(hash, forHTTPHeaderField: "X-Payghaam-Identity-Hash")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw PayghaamApiError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
