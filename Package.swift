// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "autor3search-swift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "autor3search-swift", targets: ["autor3search-swift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "autor3search-swift",
            dependencies: [
                "AutoR3SearchKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "AutoR3SearchKit",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "AutoR3SearchKitTests", dependencies: ["AutoR3SearchKit"]),
    ]
)
