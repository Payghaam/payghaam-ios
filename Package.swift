// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EngageKaro",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "EngageKaro", targets: ["EngageKaro"]),
    ],
    targets: [
        .target(name: "EngageKaro", path: "Sources/EngageKaro"),
    ]
)
