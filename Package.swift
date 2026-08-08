// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Payghaam",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Payghaam", targets: ["Payghaam"]),
    ],
    targets: [
        .target(name: "Payghaam", path: "Sources/Payghaam"),
    ]
)
