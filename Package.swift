// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NGMBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NGMBridgeCore", targets: ["NGMBridgeCore"]),
        .executable(name: "NGMBridge", targets: ["NGMBridgeApp"])
    ],
    targets: [
        .target(name: "NGMBridgeCore"),
        .executableTarget(
            name: "NGMBridgeApp",
            dependencies: ["NGMBridgeCore"]
        ),
        .testTarget(
            name: "NGMBridgeCoreTests",
            dependencies: ["NGMBridgeCore"]
        )
    ]
)
