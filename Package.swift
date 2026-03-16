// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SWUINeovimWorkspace",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SWUINeovim", targets: ["SWUINeovim"]),
        .executable(name: "SWUINeovimMac", targets: ["SWUINeovimMac"]),
    ],
    dependencies: [
        .package(path: "Packages/MsgPack"),
        .package(path: "Packages/NvimRPC"),
        .package(path: "Packages/Transport"),
    ],
    targets: [
        .target(
            name: "SWUINeovim",
            dependencies: [
                .product(name: "MsgPack", package: "MsgPack"),
                .product(name: "NvimRPC", package: "NvimRPC"),
                .product(name: "Transport", package: "Transport"),
            ],
            path: "SWUINeovim",
            exclude: [
                "App",
                "Resources",
                "Views/EditorView.swift",
                "Views/EditorSurface.swift",
            ],
            resources: [
                .copy("Rendering/Shaders/GlyphShader.metal")
            ]
        ),
        .testTarget(
            name: "SWUINeovimTests",
            dependencies: ["SWUINeovim"],
            path: "SWUINeovimTests"
        ),
        .executableTarget(
            name: "SWUINeovimMac",
            dependencies: [
                "SWUINeovim",
                .product(name: "MsgPack", package: "MsgPack"),
                .product(name: "NvimRPC", package: "NvimRPC"),
                .product(name: "Transport", package: "Transport"),
            ],
            path: "Sources/SWUINeovimMac"
        ),
    ]
)
