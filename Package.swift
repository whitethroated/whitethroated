// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "WhiteThroated",
    platforms: [
        .macOS(.v13)
    ],
    products: [
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
            name: "WhiteThroated",
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
        .testTarget(
            name: "WhiteThroatedTests",
            dependencies: [
                "WhiteThroated",
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
