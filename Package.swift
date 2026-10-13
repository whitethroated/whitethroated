// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Hudhud",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Hudhud",
            targets: ["Hudhud"]
        ),
        .executable(
            name: "hudhud-example",
            targets: ["HudhudExample"]
        ),
        .executable(
            name: "hudhud-benchmark-server",
            targets: ["HudhudBenchmarkServer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.65.0"
        )
    ],
    targets: [
        .target(
            name: "Hudhud",
            dependencies: [
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOPosix",
                    package: "swift-nio"
                )
            ]
        ),
        .executableTarget(
            name: "HudhudExample",
            dependencies: ["Hudhud"]
        ),
        .executableTarget(
            name: "HudhudBenchmarkServer",
            dependencies: ["Hudhud"],
            path: "Benchmarks/HudhudBenchmarkServer"
        ),
        .testTarget(
            name: "HudhudTests",
            dependencies: [
                "Hudhud",
                .product(
                    name: "NIOEmbedded",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                )
            ]
        )
    ]
)
