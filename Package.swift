// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "WhiteThroated",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "whitethroated-benchmark-campaign",
            targets: ["BenchmarkCampaign"]
        ),
        .executable(
            name: "whitethroated-benchmark-merge",
            targets: ["BenchmarkResultMerge"]
        ),
        .library(
            name: "WhiteThroated",
            targets: ["WhiteThroated"]
        ),
        .executable(
            name: "whitethroated-example",
            targets: ["WhiteThroatedExample"]
        ),
        .executable(
            name: "whitethroated-benchmark-server",
            targets: ["WhiteThroatedBenchmarkServer"]
        ),
        .executable(
            name: "raw-nio-benchmark-server",
            targets: ["RawNIOBenchmarkServer"]
        ),
        .executable(
            name: "whitethroated-benchmark-client",
            targets: ["WhiteThroatedBenchmarkClient"]
        ),
        .executable(
            name: "whitethroated-runtime-benchmark-server",
            targets: ["WhiteThroatedRuntimeBenchmarkServer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.104.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "BenchmarkCampaign",
            dependencies: ["BenchmarkResults"],
            path: "Benchmarks/BenchmarkCampaign"
        ),
        .target(name: "BenchmarkResults", path: "Benchmarks/BenchmarkResults"),
        .executableTarget(
            name: "BenchmarkResultMerge",
            dependencies: ["BenchmarkResults"],
            path: "Benchmarks/BenchmarkResultMerge"
        ),
        .testTarget(name: "BenchmarkResultsTests", dependencies: ["BenchmarkResults"]),
        .testTarget(
            name: "BenchmarkClientTests",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .target(
            name: "WhiteThroated",
            dependencies: [
                "WhiteThroatedRuntime",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedHTTP1",
            dependencies: [
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                )
            ]
        ),
        .target(
            name: "WhiteThroatedRuntime",
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
                ),
                "WhiteThroatedHTTP1",
            ]
        ),
        .executableTarget(
            name: "WhiteThroatedExample",
            dependencies: ["WhiteThroated"]
        ),
        .executableTarget(
            name: "WhiteThroatedBenchmarkServer",
            dependencies: ["WhiteThroated"],
            path: "Benchmarks/WhiteThroatedBenchmarkServer"
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
        .executableTarget(
            name: "WhiteThroatedBenchmarkClient",
            dependencies: [
                "BenchmarkResults",
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
            path: "Benchmarks/WhiteThroatedBenchmarkClient"
        ),
        .executableTarget(
            name: "WhiteThroatedRuntimeBenchmarkServer",
            dependencies: ["WhiteThroatedRuntime"],
            path: "Benchmarks/WhiteThroatedRuntimeBenchmarkServer"
        ),
        .testTarget(
            name: "WhiteThroatedHTTP1Tests",
            dependencies: [
                "WhiteThroatedHTTP1",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
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
                ),
            ]
        ),
        .testTarget(
            name: "WhiteThroatedTests",
            dependencies: [
                "WhiteThroated",
                "WhiteThroatedRuntime",
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
        ),
        .testTarget(
            name: "WhiteThroatedRuntimeTests",
            dependencies: [
                "WhiteThroatedRuntime",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
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
                ),
            ]
        )
    ]
)
