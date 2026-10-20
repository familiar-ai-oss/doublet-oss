// swift-tools-version: 6.0
// DuetKit: the hub protocol, the WebSocket connection and the observable store, shared by the Mac and iOS apps.
import PackageDescription

let package = Package(
    name: "DuetKit",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "DuetKit", targets: ["DuetKit"])],
    targets: [
        .target(name: "DuetKit"),
        .testTarget(name: "DuetKitTests", dependencies: ["DuetKit"]),
    ]
)
