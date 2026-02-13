// swift-tools-version: 5.9
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
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0")
    ],
    targets: [
        .target(
            name: "EvenG1Core",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources/EvenG1Core"
        ),
        .testTarget(
            name: "EvenG1CoreTests",
            dependencies: ["EvenG1Core"],
            path: "Tests/EvenG1CoreTests"
        )
    ]
)
