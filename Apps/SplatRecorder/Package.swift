// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "SplatRecorder",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "SplatRecorder",
            dependencies: [
                .product(name: "MetalSplatter", package: "MetalSplatter"),
                .product(name: "SplatIO", package: "MetalSplatter"),
                .product(name: "PLYIO", package: "MetalSplatter"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "SplatRecorderTests",
            dependencies: [
                "SplatRecorder",
                .product(name: "SplatIO", package: "MetalSplatter"),
            ],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
