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
        .executable(
            name: "whitethroated-benchmark-ab-compare",
            targets: ["BenchmarkABCompare"]
        ),
        .executable(
            name: "whitethroated-response-stream-ab-driver",
            targets: ["BenchmarkResponseStreamABDriver"]
        ),
        .library(
            name: "WhiteThroated",
            targets: ["WhiteThroated"]
        ),
        .library(
            name: "WhiteThroatedCORS",
            targets: ["WhiteThroatedCORS"]
        ),
        .library(
            name: "WhiteThroatedStaticFiles",
            targets: ["WhiteThroatedStaticFiles"]
        ),
        .library(
            name: "WhiteThroatedValidation",
            targets: ["WhiteThroatedValidation"]
        ),
        .library(
            name: "WhiteThroatedRateLimit",
            targets: ["WhiteThroatedRateLimit"]
        ),
        .library(
            name: "WhiteThroatedLogging",
            targets: ["WhiteThroatedLogging"]
        ),
        .library(
            name: "WhiteThroatedMetrics",
            targets: ["WhiteThroatedMetrics"]
        ),
        .library(
            name: "WhiteThroatedTracing",
            targets: ["WhiteThroatedTracing"]
        ),
        .library(
            name: "WhiteThroatedLifecycle",
            targets: ["WhiteThroatedLifecycle"]
        ),
        .library(
            name: "WhiteThroatedAuth",
            targets: ["WhiteThroatedAuth"]
        ),
        .library(
            name: "WhiteThroatedSessions",
            targets: ["WhiteThroatedSessions"]
        ),
        .library(
            name: "WhiteThroatedRedisSessions",
            targets: ["WhiteThroatedRedisSessions"]
        ),
        .library(
            name: "WhiteThroatedCSRF",
            targets: ["WhiteThroatedCSRF"]
        ),
        .library(
            name: "WhiteThroatedAuthRateLimit",
            targets: ["WhiteThroatedAuthRateLimit"]
        ),
        .library(
            name: "WhiteThroatedServices",
            targets: ["WhiteThroatedServices"]
        ),
        .library(
            name: "WhiteThroatedDatabase",
            targets: ["WhiteThroatedDatabase"]
        ),
        .library(
            name: "WhiteThroatedPostgres",
            targets: ["WhiteThroatedPostgres"]
        ),
        .library(
            name: "WhiteThroatedMigrations",
            targets: ["WhiteThroatedMigrations"]
        ),
        .library(
            name: "WhiteThroatedORM",
            targets: ["WhiteThroatedORM"]
        ),
        .library(
            name: "WhiteThroatedCompression",
            targets: ["WhiteThroatedCompression"]
        ),
        .library(
            name: "WhiteThroatedTLS",
            targets: ["WhiteThroatedTLS"]
        ),
        .library(
            name: "WhiteThroatedWebSocket",
            targets: ["WhiteThroatedWebSocket"]
        ),
        .library(
            name: "WhiteThroatedOpenAPI",
            targets: ["WhiteThroatedOpenAPI"]
        ),
        .executable(
            name: "whitethroated-example",
            targets: ["WhiteThroatedExample"]
        ),
        .executable(
            name: "whitethroated-deployment-example",
            targets: ["WhiteThroatedDeploymentExample"]
        ),
        .executable(
            name: "whitethroated-migrate",
            targets: ["WhiteThroatedMigrationCLI"]
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
        ),
        .executable(
            name: "whitethroated-websocket-benchmark-server",
            targets: ["WhiteThroatedWebSocketBenchmarkServer"]
        ),
        .executable(
            name: "whitethroated-websocket-benchmark-client",
            targets: ["WhiteThroatedWebSocketBenchmarkClient"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.104.0"
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "4.5.2"
        ),
        .package(
            url: "https://github.com/swift-server/RediStack.git",
            exact: "1.6.3"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            exact: "2.37.5"
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
        .executableTarget(
            name: "BenchmarkABCompare",
            dependencies: ["BenchmarkResults"],
            path: "Benchmarks/BenchmarkABCompare"
        ),
        .executableTarget(
            name: "BenchmarkResponseStreamABDriver",
            path: "Benchmarks/BenchmarkResponseStreamABDriver"
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
            name: "WhiteThroatedCORS",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedStaticFiles",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                ),
                .product(
                    name: "_NIOFileSystem",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedValidation",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedRateLimit",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedLogging",
            dependencies: [
                "WhiteThroated",
            ]
        ),
        .target(
            name: "WhiteThroatedMetrics",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedTracing",
            dependencies: [
                "WhiteThroated",
            ]
        ),
        .target(
            name: "WhiteThroatedLifecycle",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedAuth",
            dependencies: [
                "WhiteThroated",
            ]
        ),
        .target(
            name: "WhiteThroatedSessions",
            dependencies: [
                "WhiteThroated",
                "WhiteThroatedAuth",
                .product(
                    name: "Crypto",
                    package: "swift-crypto"
                ),
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedRedisSessions",
            dependencies: [
                "WhiteThroatedSessions",
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
                .product(
                    name: "RediStack",
                    package: "RediStack"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedCSRF",
            dependencies: [
                "WhiteThroated",
                "WhiteThroatedSessions",
                .product(
                    name: "Crypto",
                    package: "swift-crypto"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedAuthRateLimit",
            dependencies: [
                "WhiteThroated",
                "WhiteThroatedAuth",
                "WhiteThroatedRateLimit",
                .product(
                    name: "Crypto",
                    package: "swift-crypto"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedServices",
            dependencies: [
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedDatabase"
        ),
        .systemLibrary(
            name: "CPostgres",
            path: "Sources/CPostgres",
            pkgConfig: "libpq",
            providers: [
                .brew(["libpq"]),
                .apt(["libpq-dev"]),
            ]
        ),
        .target(
            name: "WhiteThroatedPostgres",
            dependencies: [
                "WhiteThroatedDatabase",
                "CPostgres",
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedMigrations",
            dependencies: [
                "WhiteThroatedDatabase",
                .product(
                    name: "Crypto",
                    package: "swift-crypto"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedORM",
            dependencies: [
                "WhiteThroatedDatabase",
            ]
        ),
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            pkgConfig: "zlib",
            providers: [
                .brew(["zlib"]),
                .apt(["zlib1g-dev"]),
            ]
        ),
        .target(
            name: "WhiteThroatedCompression",
            dependencies: [
                "WhiteThroated",
                "CZlib",
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
            name: "WhiteThroatedTLS",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOSSL",
                    package: "swift-nio-ssl"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedWebSocket",
            dependencies: [
                "WhiteThroated",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOWebSocket",
                    package: "swift-nio"
                ),
            ]
        ),
        .target(
            name: "WhiteThroatedOpenAPI",
            dependencies: [
                "WhiteThroated",
                "WhiteThroatedValidation",
            ]
        ),
        .executableTarget(
            name: "WhiteThroatedMigrationCLI",
            dependencies: [
                "WhiteThroatedDatabase",
                "WhiteThroatedMigrations",
                "WhiteThroatedPostgres",
            ]
        ),
        .target(
            name: "WhiteThroatedDatabaseTestSupport",
            dependencies: [
                "WhiteThroatedDatabase",
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
            ],
            path: "Tests/Support/DatabaseTestSupport"
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
            name: "WhiteThroatedDeploymentExample",
            dependencies: [
                "WhiteThroated",
                "WhiteThroatedLifecycle",
            ]
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
        .executableTarget(
            name: "WhiteThroatedWebSocketBenchmarkServer",
            dependencies: [
                "WhiteThroated",
                "WhiteThroatedWebSocket",
            ],
            path:
                "Benchmarks/WhiteThroatedWebSocketBenchmarkServer"
        ),
        .executableTarget(
            name: "WhiteThroatedWebSocketBenchmarkClient",
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
                .product(
                    name: "NIOWebSocket",
                    package: "swift-nio"
                ),
            ],
            path:
                "Benchmarks/WhiteThroatedWebSocketBenchmarkClient"
        ),
        .testTarget(
            name: "WhiteThroatedCORSTests",
            dependencies: [
                "WhiteThroatedCORS",
                "WhiteThroated",
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
        .testTarget(
            name: "WhiteThroatedStaticFilesTests",
            dependencies: [
                "WhiteThroatedStaticFiles",
                "WhiteThroatedCompression",
                "WhiteThroated",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio"
                ),
                .product(
                    name: "_NIOFileSystem",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOPosix",
                    package: "swift-nio"
                ),
            ]
        ),
        .testTarget(
            name: "WhiteThroatedValidationTests",
            dependencies: [
                "WhiteThroatedValidation",
                "WhiteThroated",
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
            ]
        ),
        .testTarget(
            name: "WhiteThroatedRateLimitTests",
            dependencies: [
                "WhiteThroatedRateLimit",
                "WhiteThroated",
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
            ]
        ),
        .testTarget(
            name: "WhiteThroatedObservabilityTests",
            dependencies: [
                "WhiteThroatedLogging",
                "WhiteThroatedMetrics",
                "WhiteThroatedTracing",
                "WhiteThroatedLifecycle",
                "WhiteThroated",
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
            ]
        ),
        .testTarget(
            name: "WhiteThroatedIdentityStateTests",
            dependencies: [
                "WhiteThroatedAuth",
                "WhiteThroatedSessions",
                "WhiteThroatedRedisSessions",
                "WhiteThroatedCSRF",
                "WhiteThroatedAuthRateLimit",
                "WhiteThroatedRateLimit",
                "WhiteThroated",
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
            ]
        ),
        .testTarget(
            name: "WhiteThroatedDataServicesTests",
            dependencies: [
                "WhiteThroatedServices",
                "WhiteThroatedLifecycle",
                "WhiteThroatedDatabase",
                "WhiteThroatedDatabaseTestSupport",
                "WhiteThroated",
                .product(
                    name: "NIOConcurrencyHelpers",
                    package: "swift-nio"
                ),
            ]
        ),
        .testTarget(
            name: "WhiteThroatedDatabaseTests",
            dependencies: [
                "WhiteThroatedDatabase",
                "WhiteThroatedDatabaseTestSupport",
            ]
        ),
        .testTarget(
            name: "WhiteThroatedMigrationsTests",
            dependencies: [
                "WhiteThroatedMigrations",
                "WhiteThroatedDatabase",
                "WhiteThroatedDatabaseTestSupport",
            ]
        ),
        .testTarget(
            name: "WhiteThroatedORMTests",
            dependencies: [
                "WhiteThroatedORM",
                "WhiteThroatedDatabase",
                "WhiteThroatedDatabaseTestSupport",
            ]
        ),
        .testTarget(
            name: "WhiteThroatedCompressionTests",
            dependencies: [
                "WhiteThroatedCompression",
                "WhiteThroated",
                "CZlib",
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
            name: "WhiteThroatedTLSTests",
            dependencies: [
                "WhiteThroatedTLS",
                "WhiteThroated",
                .product(
                    name: "NIOCore",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOEmbedded",
                    package: "swift-nio"
                ),
                .product(
                    name: "NIOSSL",
                    package: "swift-nio-ssl"
                ),
            ]
        ),
        .testTarget(
            name: "WhiteThroatedWebSocketTests",
            dependencies: [
                "WhiteThroatedWebSocket",
                "WhiteThroatedAuth",
                "WhiteThroated",
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
                    name: "NIOWebSocket",
                    package: "swift-nio"
                ),
            ]
        ),
        .testTarget(
            name: "WhiteThroatedOpenAPITests",
            dependencies: [
                "WhiteThroatedOpenAPI",
                "WhiteThroatedValidation",
                "WhiteThroated",
            ]
        ),
        .testTarget(
            name: "WhiteThroatedPostgresTests",
            dependencies: [
                "WhiteThroatedPostgres",
                "WhiteThroatedDatabase",
                "WhiteThroatedMigrations",
                "CPostgres",
            ]
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
