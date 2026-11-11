// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TFTLive",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TFTLive", targets: ["TFTLiveApp"]),
        .executable(name: "TFTLiveCLI", targets: ["TFTLiveCLI"]),
        .executable(name: "SDKHost", targets: ["SDKHost"])
    ],
    targets: [
        .target(name: "TFTCore"),
        .executableTarget(name: "SDKHost", dependencies: ["TFTCore"]),
        .executableTarget(name: "TFTLiveCLI", dependencies: ["TFTCore"]),
        .executableTarget(name: "TFTLiveApp", dependencies: ["TFTCore"]),
        .testTarget(name: "TFTCoreTests", dependencies: ["TFTCore"])
    ]
)
