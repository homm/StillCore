// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenuStatsBenchmarks",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/google/swift-benchmark.git", from: "0.1.2"),
    ],
    targets: [
        .executableTarget(
            name: "MenuStatsBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "swift-benchmark"),
            ]
        ),
    ]
)
