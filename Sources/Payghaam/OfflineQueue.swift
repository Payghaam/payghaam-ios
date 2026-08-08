import Foundation

// Persistent offline queue for fire-and-forget SDK calls (events, tags,
// receipts, subscriptions). Calls made while offline are parked in
// UserDefaults and drained FIFO on the next app-active / successful send.
struct QueuedOp: Codable {
    let method: String
    let path: String
    let body: Data // JSON-serialized
    let queuedAt: Date
}

enum OfflineQueue {
    private static let storageKey = "payghaam.queue.v1"
    private static let maxQueue = 200
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private static let lock = NSLock()
    private static var flushing = false

    private static func loadOps() -> [QueuedOp] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let ops = try? JSONDecoder().decode([QueuedOp].self, from: data)
        else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        return ops.filter { $0.queuedAt > cutoff }
    }

    private static func saveOps(_ ops: [QueuedOp]) {
        if let data = try? JSONEncoder().encode(ops) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // HTTP 4xx (except 408/429) means the payload will never be accepted;
    // everything else (network, timeout, 5xx) is worth retrying.
    static func isRetryable(_ error: Error) -> Bool {
        if let api = error as? PayghaamApiError {
            return api.statusCode == 408 || api.statusCode == 429 || api.statusCode >= 500
        }
        return true
    }

    /// Runs `body` while holding `lock`, and — critically — is itself a plain
    /// (non-async) function. `NSLock.lock()`/`unlock()` are `@available(*,
    /// noasync)` in current SDKs: calling them directly from inside an `async
    /// func`'s own body (as `flush` below is) warns today and hard-errors under
    /// Swift 6 language mode. Routing every lock/unlock through this synchronous
    /// helper means the actual NSLock calls are lexically inside a sync function,
    /// which satisfies the check regardless of what async context calls in. Never
    /// pass a `body` that itself suspends — these sections must stay synchronous.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func enqueue(method: String, path: String, body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        withLock {
            var ops = loadOps()
            ops.append(QueuedOp(method: method, path: path, body: data, queuedAt: Date()))
            if ops.count > maxQueue { ops.removeFirst(ops.count - maxQueue) }
            saveOps(ops)
        }
    }

    /// Drain FIFO. Stops at the first retryable failure (still offline); drops
    /// ops the server permanently rejects. Safe to call repeatedly.
    static func flush(config: PayghaamConfig) async {
        let alreadyFlushing = withLock { () -> Bool in
            if flushing { return true }
            flushing = true
            return false
        }
        if alreadyFlushing { return }
        defer { withLock { flushing = false } }

        while true {
            let op: QueuedOp? = withLock { loadOps().first }
            guard let op else { return }

            do {
                let body = (try? JSONSerialization.jsonObject(with: op.body)) as? [String: Any] ?? [:]
                try await ApiClient.rawRequest(config: config, method: op.method, path: op.path, body: body)
            } catch {
                if isRetryable(error) { return } // still offline — retry later
                // fall through: permanently rejected, drop it
            }

            withLock {
                var ops = loadOps()
                if !ops.isEmpty { ops.removeFirst() }
                saveOps(ops)
            }
        }
    }
}
