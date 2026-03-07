// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MsgPack",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "MsgPack",
            targets: ["MsgPack"]
        ),
    ],
    targets: [
        .target(
            name: "MsgPack",
            path: "Sources/MsgPack"
        ),
        .testTarget(
            name: "MsgPackTests",
            dependencies: ["MsgPack"],
            path: "Tests/MsgPackTests"
        ),
    ]
)