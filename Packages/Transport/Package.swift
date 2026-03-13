// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transport",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "Transport",
            targets: ["Transport"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "Transport",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ],
            path: "Sources/Transport",
            exclude: [
                "LocalTransport.swift",
            ]
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["Transport"],
            path: "Tests/TransportTests"
        ),
    ]
)