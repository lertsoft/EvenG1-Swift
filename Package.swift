// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EvenG1",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "EvenG1Core",
            targets: ["EvenG1Core"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
        .package(url: "https://github.com/Datadog/dd-sdk-ios.git", from: "2.14.0")
    ],
    targets: [
        .target(
            name: "CLibLC3",
            path: "Sources/CLibLC3",
            exclude: ["LICENSE", "UPSTREAM.md"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        .target(
            name: "EvenG1Core",
            dependencies: [
                "CLibLC3",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "DatadogCore", package: "dd-sdk-ios"),
                .product(name: "DatadogRUM", package: "dd-sdk-ios"),
                .product(name: "DatadogCrashReporting", package: "dd-sdk-ios")
            ],
            path: "Sources/EvenG1Core"
        ),
        .testTarget(
            name: "EvenG1CoreTests",
            dependencies: ["EvenG1Core", "CLibLC3"],
            path: "Tests/EvenG1CoreTests"
        )
    ]
)
