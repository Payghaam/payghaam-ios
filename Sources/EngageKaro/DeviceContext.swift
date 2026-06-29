import Foundation
import UIKit

enum DeviceContext {
    static let sdkVersion = "0.1.0"

    static func collect(sessionStart: Bool = false, pushPermission: String? = nil) -> [String: Any] {
        let locale = Locale.current
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        var body: [String: Any] = [
            "country": locale.regionCode ?? "",
            "language": locale.languageCode ?? "",
            "timezone": TimeZone.current.identifier,
            "os": "iOS",
            "osVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model,
            "sdkVersion": sdkVersion,
        ]
        if let appVersion { body["appVersion"] = appVersion }
        if let pushPermission { body["pushPermission"] = pushPermission }
        if sessionStart { body["sessionStart"] = true }
        return body
    }
}

final class SessionTracker {
    private var lastSessionAt: Date?
    private var countedThisLaunch = false
    private let gap: TimeInterval = 30 * 60

    func noteForeground(now: Date = Date()) -> Bool {
        if countedThisLaunch, let last = lastSessionAt, now.timeIntervalSince(last) < gap {
            return false
        }
        if let last = lastSessionAt, now.timeIntervalSince(last) < gap {
            return false
        }
        lastSessionAt = now
        countedThisLaunch = true
        return true
    }
}
