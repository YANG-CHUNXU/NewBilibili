// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NewBiCore",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "NewBiCore",
            targets: ["NewBiCore"]
        )
    ],
    targets: [
        .target(
            name: "NewBiCore"
        ),
        .testTarget(
            name: "NewBiCoreTests",
            dependencies: ["NewBiCore"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
