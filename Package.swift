// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhiteNoiseSDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .watchOS(.v9),
        .tvOS(.v16),
    ],
    products: [
        .library(
            name: "WhiteNoiseSDK",
            targets: ["WhiteNoiseSDK"]
        ),
    ],
    targets: [
        .target(
            name: "WhiteNoiseSDK",
            path: "Sources/WhiteNoiseSDK"
        ),
        .testTarget(
            name: "WhiteNoiseSDKTests",
            dependencies: ["WhiteNoiseSDK"],
            path: "Tests/WhiteNoiseSDKTests"
        ),
    ]
)
