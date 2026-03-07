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
    targets: [
        .target(
            name: "Transport",
            path: "Sources/Transport",
            exclude: [
                "LocalTransport.swift",
                "SSHTransport.swift",
            ]
        ),
        .testTarget(
            name: "TransportTests",
            dependencies: ["Transport"],
            path: "Tests/TransportTests"
        ),
    ]
)