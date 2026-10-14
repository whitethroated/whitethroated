// swift-tools-version: 6.1

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
        ),
        .executable(
            name: "raw-nio-benchmark-server",
            targets: ["RawNIOBenchmarkServer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.104.0"
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
        .executableTarget(
            name: "RawNIOBenchmarkServer",
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
            ],
            path: "Benchmarks/RawNIOBenchmarkServer"
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
                ),
                .product(
                    name: "NIOPosix",
                    package: "swift-nio"
                )
            ]
        )
    ]
)
