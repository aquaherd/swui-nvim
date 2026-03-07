// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NvimRPC",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "NvimRPC", targets: ["NvimRPC"]),
    ],
    dependencies: [
        .package(path: "../MsgPack"),
    ],
    targets: [
        .target(
            name: "NvimRPC",
            dependencies: [
                .product(name: "MsgPack", package: "MsgPack"),
            ]
        ),
        .testTarget(
            name: "NvimRPCTests",
            dependencies: ["NvimRPC"]
        ),
    ]
)