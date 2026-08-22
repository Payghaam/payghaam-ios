#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import Foundation

/// Posted after a Live Activity update-token POST succeeds or fails.
///
/// `userInfo`: `activityId` (String), `ok` (Bool), optional `tokenPrefix` /
/// `error` (String). Host apps should listen here instead of also consuming
/// `activity.pushTokenUpdates` — a second iterator can starve the SDK.
public extension Notification.Name {
    static let payghaamLiveActivityUpdateToken =
        Notification.Name("PayghaamLiveActivityUpdateToken")
    static let payghaamLiveActivityStartToken =
        Notification.Name("PayghaamLiveActivityStartToken")
}

/// Live Activity token plumbing.
///
/// Two token streams, both observed continuously:
///
/// * **push-to-start** — one per app install (iOS 17.2+), registered as
///   `IOS_LIVE_ACTIVITY_START`.
/// * **update tokens** — one per running activity, registered per activity.
///
/// Call `observe(_:)` once at app launch (before `login()`). The SDK re-attaches
/// on foreground and push wake via `refreshAll()`.
@available(iOS 16.1, *)
public enum PayghaamLiveActivities {
    #if canImport(ActivityKit)

    private static let lock = NSLock()
    /// ActivityKit ids we already attached `pushTokenUpdates` to.
    private static var observingKitIds = Set<String>()
    private static var observingTypeNames = Set<String>()
    private static var rescanHooks: [() -> Void] = []
    private static var foregroundHookInstalled = false

    private static func removeObservingKitId(_ id: String) {
        lock.lock()
        observingKitIds.remove(id)
        lock.unlock()
    }

    /// Begin observing both token streams for `Attributes`.
    public static func observe<Attributes: ActivityAttributes>(
        _ type: Attributes.Type,
        attributesTypeName: String? = nil
    ) {
        let typeName = attributesTypeName ?? String(describing: Attributes.self)

        lock.lock()
        let alreadyObservingType = observingTypeNames.contains(typeName)
        if !alreadyObservingType {
            observingTypeNames.insert(typeName)
        }
        lock.unlock()

        if #available(iOS 17.2, *), !alreadyObservingType {
            Task.detached(priority: .utility) {
                for await tokenData in Activity<Attributes>.pushToStartTokenUpdates {
                    await registerPushToStart(hex(tokenData))
                }
            }
        }

        let rescan: () -> Void = {
            for activity in Activity<Attributes>.activities {
                observeUpdates(of: activity, typeName: typeName)
            }
        }
        if !alreadyObservingType {
            lock.lock()
            rescanHooks.append(rescan)
            lock.unlock()
            installForegroundHookIfNeeded()
        }

        rescan()

        if alreadyObservingType { return }

        Task.detached(priority: .utility) {
            for await activity in Activity<Attributes>.activityUpdates {
                observeUpdates(of: activity, typeName: typeName)
                // Token often lands shortly after the activity appears.
                refreshAllDelayedRetry(reason: "activityUpdates")
            }
        }
    }

    /// End every running activity of `Attributes`.
    public static func endAll<Attributes: ActivityAttributes>(
        _ type: Attributes.Type,
        finalState: Attributes.ContentState
    ) async {
        #if canImport(ActivityKit)
        for activity in Activity<Attributes>.activities {
            if #available(iOS 16.2, *) {
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            } else {
                await activity.end(using: finalState, dismissalPolicy: .immediate)
            }
            removeObservingKitId(activity.id)
        }
        #endif
    }

    /// Re-attach to activities ActivityKit currently knows about.
    public static func refresh<Attributes: ActivityAttributes>(
        _ type: Attributes.Type,
        attributesTypeName: String? = nil
    ) {
        let typeName = attributesTypeName ?? String(describing: Attributes.self)
        for activity in Activity<Attributes>.activities {
            observeUpdates(of: activity, typeName: typeName)
        }
    }

    /// Re-scan every attributes type passed to `observe()`.
    public static func refreshAll() {
        #if canImport(ActivityKit)
        lock.lock()
        let hooks = rescanHooks
        lock.unlock()
        guard !hooks.isEmpty else { return }
        for hook in hooks { hook() }
        #endif
    }

    /// Push wake / remote start may mint `pushToken` shortly after the activity
    /// appears. One immediate rescan plus a couple of delayed retries covers that
    /// without aggressive polling.
    public static func refreshAllDelayedRetry(reason: String = "push_wake") {
        refreshAll()
        Task.detached(priority: .utility) {
            for (i, delayNs) in [500_000_000, 2_000_000_000].enumerated() {
                try? await Task.sleep(nanoseconds: UInt64(delayNs))
                refreshAll()
                if i == 0 {
                    NSLog("[Payghaam] Live Activity refresh retry reason=\(reason)")
                }
            }
        }
    }

    private static func installForegroundHookIfNeeded() {
        #if canImport(UIKit)
        lock.lock()
        let shouldInstall = !foregroundHookInstalled
        if shouldInstall { foregroundHookInstalled = true }
        lock.unlock()
        guard shouldInstall else { return }

        let onActivate: () -> Void = { refreshAll() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in onActivate() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in onActivate() }
        #endif
    }

    private static func observeUpdates<Attributes: ActivityAttributes>(
        of activity: Activity<Attributes>,
        typeName: String
    ) {
        let kitId = activity.id
        let handle = activityId(of: activity)

        // Post any token ActivityKit already holds (common after push-to-start).
        if let existing = activity.pushToken {
            let token = hex(existing)
            Task.detached(priority: .utility) {
                _ = await register(activityId: handle, token: token, attributesType: typeName)
            }
        } else if activity.activityState == .active {
            NSLog(
                "[Payghaam] Live Activity pushToken nil activityId=\(handle) "
                    + "state=\(activity.activityState)\(pushToStartTokenHint)"
            )
        }

        lock.lock()
        let already = observingKitIds.contains(kitId)
        if !already { observingKitIds.insert(kitId) }
        lock.unlock()
        if already { return }

        Task.detached(priority: .utility) {
            for await tokenData in activity.pushTokenUpdates {
                let token = hex(tokenData)
                _ = await register(activityId: handle, token: token, attributesType: typeName)
            }
            removeObservingKitId(kitId)
        }
    }

    private static func activityId<Attributes: ActivityAttributes>(
        of activity: Activity<Attributes>
    ) -> String {
        if let identifiable = activity.attributes as? PayghaamLiveActivityIdentifiable {
            return identifiable.payghaamActivityId
        }
        return activity.id
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Push-to-start withholds the update token until the user taps Allow on the
    /// lock-screen activity UI. Local starts mint a token without that step.
    private static let pushToStartTokenHint =
        " — push-to-start: tap Allow on the lock-screen activity UI"

    #endif
}

/// Opt-in so the customer's own identifier is used as the activity handle.
public protocol PayghaamLiveActivityIdentifiable {
    var payghaamActivityId: String { get }
}

@available(iOS 16.1, *)
extension PayghaamLiveActivities {
    fileprivate static func registerPushToStart(_ token: String) async {
        await Payghaam.shared.registerLiveActivityStartToken(token)
    }

    fileprivate static func register(
        activityId: String,
        token: String,
        attributesType: String
    ) async -> Bool {
        await Payghaam.shared.registerLiveActivityUpdateToken(
            activityId: activityId,
            token: token,
            attributesType: attributesType
        )
    }
}
