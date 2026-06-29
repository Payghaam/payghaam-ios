import Foundation

public struct EngageKaroConfig: Sendable {
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
}

public struct EngageKaroApiError: Error, LocalizedError {
    public let statusCode: Int
    public let body: String
    public var errorDescription: String? { "EngageKaroApiError(\(statusCode)): \(body)" }
}

enum ApiClient {
    static var identityHash: String?

    static func identify(
        config: EngageKaroConfig,
        externalId: String?,
        deviceContext: [String: Any]? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let externalId { body["externalId"] = externalId }
        deviceContext?.forEach { body[$0.key] = $0.value }
        try await post(config: config, path: "/users", body: body)
    }

    static func addSubscription(
        config: EngageKaroConfig,
        externalId: String,
        type: SubscriptionType,
        token: String
    ) async throws {
        try await post(config: config, path: "/users/\(externalId)/subscriptions", body: [
            "type": type.rawValue,
            "token": token,
        ])
    }

    static func updateTags(config: EngageKaroConfig, externalId: String, tags: [String: Any?]) async throws {
        try await put(config: config, path: "/users/\(externalId)/tags", body: ["tags": tags])
    }

    static func track(
        config: EngageKaroConfig,
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
        config: EngageKaroConfig,
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

    private static func post(config: EngageKaroConfig, path: String, body: [String: Any]) async throws {
        try await request(config: config, method: "POST", path: path, body: body)
    }

    private static func put(config: EngageKaroConfig, path: String, body: [String: Any]) async throws {
        try await request(config: config, method: "PUT", path: path, body: body)
    }

    private static func request(
        config: EngageKaroConfig,
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
            req.setValue(hash, forHTTPHeaderField: "X-Engagekaro-Identity-Hash")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, res) = try await URLSession.shared.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw EngageKaroApiError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
