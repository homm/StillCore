// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/google/swift-benchmark.git", from: "0.1.2"),
    ],
    targets: [
        .executableTarget(
            name: "Benchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "swift-benchmark"),
            ],
            path: "Sources"
        ),
    ]
)
