import Foundation
import UserNotifications

/// Credential-agnostic helpers for contexts where the full `Payghaam.shared`
/// singleton isn't available or safe to use — chiefly a Notification Service
/// Extension, which runs as its own process with a strict (~30s) time budget
/// and can't await the async, actor-isolated API on `Payghaam`.
///
/// Read your app's config from the App Group `UserDefaults` that
/// `Payghaam.shared.shareConfig(...)` wrote at login (keys `ek_api_base`,
/// `ek_api_key`, `ek_external_id`), and pass them here directly.
public enum PayghaamReceipts {
    /// Reports a `delivered` receipt synchronously, blocking the calling
    /// thread until the request completes or `timeout` elapses. Suited to an
    /// NSE's `didReceive(_:withContentHandler:)`, which is killed shortly
    /// after returning — an unblocked `URLSession` task would be dropped.
    public static func reportDeliveredBlocking(
        apiBase: String,
        apiKey: String,
        externalId: String?,
        identityHash: String? = nil,
        messageId: String,
        timeout: TimeInterval = 5
    ) {
        guard let url = URL(string: "\(apiBase)/api/sdk/receipts") else { return }
        var body: [String: Any] = ["messageId": messageId, "event": "delivered"]
        if let externalId { body["externalId"] = externalId }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        if let identityHash { req.setValue(identityHash, forHTTPHeaderField: "X-Payghaam-Identity-Hash") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Downloads a remote image and wraps it as a `UNNotificationAttachment`,
    /// for rich media push (the `ek_image` payload key). Async/callback-based
    /// since attaching to `bestAttempt` can happen after `didReceive` returns,
    /// as long as it's before the content handler is called.
    public static func downloadAttachment(
        url: URL,
        completion: @escaping (UNNotificationAttachment?) -> Void
    ) {
        URLSession.shared.downloadTask(with: url) { location, _, _ in
            guard let location else { completion(nil); return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + (url.pathExtension.isEmpty ? ".jpg" : "." + url.pathExtension))
            do {
                try FileManager.default.moveItem(at: location, to: tmp)
                completion(try UNNotificationAttachment(identifier: "image", url: tmp))
            } catch {
                completion(nil)
            }
        }.resume()
    }
}
