// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DemoPackage",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.36.0"),
    ],
    targets: [
        .target(name: "Demo"),
        .testTarget(name: "DemoTests", dependencies: ["Demo"]),
        .executableTarget(
            name: "Bench",
            dependencies: [
                "Demo",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/Bench",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ]
)
