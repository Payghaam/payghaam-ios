# Payghaam iOS SDK

Native Swift SDK for iOS — direct APNs push (no Firebase), user identity, tags, and events.

## Install (Swift Package Manager)

In Xcode → **File → Add Package Dependencies → Add Local…** and select `sdks/ios`.

Or in `Package.swift`:

```swift
.package(path: "../sdks/ios")
```

## Setup

1. Enable **Push Notifications**, **Background Modes → Remote notifications**, and **App Groups** on your app target.
2. Configure APNs in the Payghaam dashboard (Channels → iOS · APNs).
3. Add a Notification Service Extension for terminated-state delivery receipts (optional — see [iOS setup](../flutter/IOS_SETUP.md)).

## Quick start

```swift
import Payghaam

@main
struct MyApp: App {
    init() {
        Payghaam.shared.initialize(PayghaamConfig(
            appId: "YOUR_PROJECT_ID",
            apiKey: "ek_client_...",
            baseUrl: "https://api.yourhost.com"
        ))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// After user signs in:
Task {
    try await Payghaam.shared.login(externalId: "user-123")
    _ = await Payghaam.shared.requestPushPermission()
    Payghaam.shared.shareConfig(
        appGroup: "group.com.yourcompany.app.payghaam",
        apiBase: "https://api.yourhost.com",
        apiKey: "ek_client_...",
        externalId: "user-123"
    )
}
```

In your AppDelegate (or `@UIApplicationDelegateAdaptor`):

```swift
func application(_ application: UIApplication,
                   didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { try? await Payghaam.shared.setDeviceToken(deviceToken) }
}

// Required for push-to-start / Live Activity update token registration while suspended:
func application(_ application: UIApplication,
                   didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                   fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    Payghaam.shared.handleRemoteNotification(userInfo, fetchCompletionHandler: completionHandler)
}
```

Live Activities: call `PayghaamLiveActivities.observe(YourAttributes.self)` once at launch (before
`login()`). The SDK re-attaches on foreground, notification delivery, and the push wake handler
above. After push-to-start, the user must tap **Allow** on the lock-screen activity before
ActivityKit mints the update token.

## Handling taps and deep links

A campaign's **Deep link URL** arrives as `ek_url`, and anything you pass as `data`
on `POST /api/notifications` arrives alongside it:

```swift
Payghaam.shared.onNotificationOpened = { payload in
    // payload["ek_url"]   → "myapp://offers/summer"
    // payload["targetId"] → your own data key
    if let target = payload["targetId"] as? String { router.openOffer(target) }
}
```

If you set **no** handler, the SDK opens `ek_url` itself via `UIApplication.open`.
Setting one suppresses that, so routing — including the deep link — is yours.

A tap that cold-launches the app is buffered and replayed when you assign the handler,
so it is never dropped.

The SDK installs itself as `UNUserNotificationCenter.delegate` during `initialize`, but
keeps and forwards to whatever delegate you had set — your own notification handling
keeps working.

Reserved payload keys: `ek_message_id`, `ek_url`, `ek_image`.

## API

| Method | Description |
|--------|-------------|
| `initialize(_:)` | Required once at launch |
| `onNotificationOpened` | Handler for notification taps |
| `login(externalId:identityHash:)` | Identify user |
| `logout()` | Clear identity |
| `trackEvent(_:properties:)` | Track custom event |
| `addTag` / `addTags` | Update user tags |
| `requestPushPermission()` | Prompt + register for remote notifications |
| `setDeviceToken(_:)` | Forward APNs token from AppDelegate |
| `shareConfig(appGroup:...)` | Share creds with NSE for killed-state receipts |
