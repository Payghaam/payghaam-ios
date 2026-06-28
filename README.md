# EngageKaro iOS SDK

Native Swift SDK for iOS — direct APNs push (no Firebase), user identity, tags, and events.

## Install (Swift Package Manager)

In Xcode → **File → Add Package Dependencies → Add Local…** and select `sdks/ios`.

Or in `Package.swift`:

```swift
.package(path: "../sdks/ios")
```

## Setup

1. Enable **Push Notifications**, **Background Modes → Remote notifications**, and **App Groups** on your app target.
2. Configure APNs in the EngageKaro dashboard (Channels → iOS · APNs).
3. Add a Notification Service Extension for terminated-state delivery receipts (optional — see [iOS setup](../flutter/IOS_SETUP.md)).

## Quick start

```swift
import EngageKaro

@main
struct MyApp: App {
    init() {
        EngageKaro.shared.initialize(EngageKaroConfig(
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
    try await EngageKaro.shared.login(externalId: "user-123")
    _ = await EngageKaro.shared.requestPushPermission()
    EngageKaro.shared.shareConfig(
        appGroup: "group.com.yourcompany.app.engagekaro",
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
    Task { try? await EngageKaro.shared.setDeviceToken(deviceToken) }
}
```

## API

| Method | Description |
|--------|-------------|
| `initialize(_:)` | Required once at launch |
| `login(externalId:identityHash:)` | Identify user |
| `logout()` | Clear identity |
| `trackEvent(_:properties:)` | Track custom event |
| `addTag` / `addTags` | Update user tags |
| `requestPushPermission()` | Prompt + register for remote notifications |
| `setDeviceToken(_:)` | Forward APNs token from AppDelegate |
| `shareConfig(appGroup:...)` | Share creds with NSE for killed-state receipts |
