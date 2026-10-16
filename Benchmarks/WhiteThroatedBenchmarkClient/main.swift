import Dispatch
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private struct BenchmarkConfiguration {
    let host: String
    let port: Int
    let path: String
    let connections: Int
    let requests: Int
    let threads: Int
    let collectLatency: Bool
    let tcpNoDelay: Bool

    static func load() -> BenchmarkConfiguration {
        let environment =
            ProcessInfo.processInfo.environment

        let host =
            environment[
                "WHITETHROATED_BENCH_HOST"
            ] ?? "127.0.0.1"

        let port = positiveInt(
            environment[
                "WHITETHROATED_BENCH_PORT"
            ],
            defaultValue: 3000
        )

        let pathValue =
            environment[
                "WHITETHROATED_BENCH_PATH"
            ] ?? "/prepared"
        let path =
            pathValue.hasPrefix("/")
            ? pathValue
            : "/" + pathValue

        let requests = positiveInt(
            environment[
                "WHITETHROATED_BENCH_REQUESTS"
            ],
            defaultValue: 1_000_000
        )

        let requestedConnections = positiveInt(
            environment[
                "WHITETHROATED_BENCH_CONNECTIONS"
            ],
            defaultValue: 128
        )

        let connections =
            min(
                requestedConnections,
                requests
            )

        let threads = positiveInt(
            environment[
                "WHITETHROATED_BENCH_THREADS"
            ],
            defaultValue: System.coreCount
        )

        let collectLatency =
            environment[
                "WHITETHROATED_BENCH_LATENCY"
            ] == "1"

        let tcpNoDelay =
            environment[
                "WHITETHROATED_BENCH_TCP_NODELAY"
            ] != "0"

        return BenchmarkConfiguration(
            host: host,
            port: port,
            path: path,
            connections: connections,
            requests: requests,
            threads: threads,
            collectLatency: collectLatency,
            tcpNoDelay: tcpNoDelay
        )
    }

    private static func positiveInt(
        _ value: String?,
        defaultValue: Int
    ) -> Int {
        guard
            let value,
            let parsed = Int(value),
            parsed > 0
        else {
            return defaultValue
        }

        return parsed
    }
}

private enum BenchmarkClientError:
    Error,
    CustomStringConvertible,
    Sendable
{
    case connectionClosed(completed: Int, target: Int)
    case unexpectedStatus(UInt)

    var description: String {
        switch self {
        case .connectionClosed(let completed, let target):
            return "connection closed after \(completed) of \(target) requests"

        case .unexpectedStatus(let status):
            return "unexpected HTTP status \(status)"
        }
    }
}

private struct BenchmarkConnectionResult: Sendable {
    let completedRequests: Int
    let responseBodyBytes: Int
    let latencyNanoseconds: [UInt64]
}

private final class BenchmarkClientHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let requestHead: HTTPRequestHead
    private let targetRequests: Int
    private let collectLatency: Bool
    private let donePromise:
        EventLoopPromise<BenchmarkConnectionResult>

    private var completedRequests = 0
    private var responseBodyBytes = 0
    private var finished = false
    private var requestStartedAt: UInt64?
    private var latencyNanoseconds: [UInt64] = []

    init(
        requestHead: HTTPRequestHead,
        targetRequests: Int,
        collectLatency: Bool,
        donePromise:
            EventLoopPromise<BenchmarkConnectionResult>
    ) {
        self.requestHead = requestHead
        self.targetRequests = targetRequests
        self.collectLatency = collectLatency
        self.donePromise = donePromise

        if collectLatency {
            latencyNanoseconds.reserveCapacity(
                max(
                    0,
                    targetRequests - 1
                )
            )
        }
    }

    func wait() throws
        -> BenchmarkConnectionResult
    {
        try donePromise.futureResult.wait()
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard head.status == .ok else {
                fail(
                    BenchmarkClientError
                        .unexpectedStatus(
                            head.status.code
                        ),
                    context: context
                )
                return
            }

        case .body(let buffer):
            responseBodyBytes +=
                buffer.readableBytes

        case .end:
            guard !finished else {
                return
            }

            if
                collectLatency,
                let requestStartedAt
            {
                latencyNanoseconds.append(
                    DispatchTime.now()
                        .uptimeNanoseconds
                        - requestStartedAt
                )
            }

            completedRequests += 1

            if completedRequests >= targetRequests {
                finished = true
                donePromise.succeed(
                    BenchmarkConnectionResult(
                        completedRequests:
                            completedRequests,
                        responseBodyBytes:
                            responseBodyBytes,
                        latencyNanoseconds:
                            latencyNanoseconds
                    )
                )
                return
            }

            if collectLatency {
                requestStartedAt =
                    DispatchTime.now()
                        .uptimeNanoseconds
            }

            sendRequest(context: context)
        }
    }

    func channelInactive(
        context: ChannelHandlerContext
    ) {
        guard !finished else {
            return
        }

        fail(
            BenchmarkClientError.connectionClosed(
                completed: completedRequests,
                target: targetRequests
            ),
            context: context
        )
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        fail(
            error,
            context: context
        )
    }

    private func sendRequest(
        context: ChannelHandlerContext
    ) {
        context.write(
            wrapOutboundOut(
                .head(requestHead)
            ),
            promise: nil
        )
        context.writeAndFlush(
            wrapOutboundOut(.end(nil)),
            promise: nil
        )
    }

    private func fail(
        _ error: Error,
        context: ChannelHandlerContext
    ) {
        guard !finished else {
            return
        }

        finished = true
        donePromise.fail(error)
        context.close(promise: nil)
    }
}

private struct BenchmarkConnection {
    let channel: Channel
    let handler: BenchmarkClientHandler
    let requestHead: HTTPRequestHead

    func start() {
        channel.write(
            HTTPClientRequestPart.head(
                requestHead
            ),
            promise: nil
        )
        channel.writeAndFlush(
            HTTPClientRequestPart.end(nil),
            promise: nil
        )
    }
}

private let configuration =
    BenchmarkConfiguration.load()

let group = MultiThreadedEventLoopGroup(
    numberOfThreads: configuration.threads
)

defer {
    try? group.syncShutdownGracefully()
}

var requestHead = HTTPRequestHead(
    version: .http1_1,
    method: .GET,
    uri: configuration.path
)
requestHead.headers.add(
    name: "host",
    value:
        configuration.host
        + ":"
        + String(configuration.port)
)

let baseRequests =
    configuration.requests
    / configuration.connections
let extraRequests =
    configuration.requests
    % configuration.connections

private var connections: [BenchmarkConnection] = []
connections.reserveCapacity(
    configuration.connections
)

for index in 0..<configuration.connections {
    let targetRequests =
        baseRequests
        + (index < extraRequests ? 1 : 0)

    let donePromise =
        group.next().makePromise(
            of: BenchmarkConnectionResult.self
        )

    let handler = BenchmarkClientHandler(
        requestHead: requestHead,
        targetRequests: targetRequests,
        collectLatency:
            configuration.collectLatency,
        donePromise: donePromise
    )

    var bootstrap = ClientBootstrap(
        group: group
    )

    if configuration.tcpNoDelay {
        bootstrap = bootstrap.channelOption(
            ChannelOptions.socketOption(
                .tcp_nodelay
            ),
            value: 1
        )
    }

    bootstrap = bootstrap.channelInitializer { channel in
        channel.eventLoop
            .makeCompletedFuture {
                let pipeline =
                    channel.pipeline
                        .syncOperations

                try pipeline
                    .addHTTPClientHandlers()
                try pipeline.addHandler(
                    handler
                )
            }
    }

    let channel = try bootstrap
        .connect(
            host: configuration.host,
            port: configuration.port
        )
        .wait()

    connections.append(
        BenchmarkConnection(
            channel: channel,
            handler: handler,
            requestHead: requestHead
        )
    )
}

let start =
    DispatchTime.now()
        .uptimeNanoseconds

for connection in connections {
    connection.start()
}

private var results: [BenchmarkConnectionResult] = []
results.reserveCapacity(
    connections.count
)

for connection in connections {
    results.append(
        try connection.handler.wait()
    )
}

let end =
    DispatchTime.now()
        .uptimeNanoseconds

var completedRequests = 0
var responseBodyBytes = 0
var latencyNanoseconds: [UInt64] = []

if configuration.collectLatency {
    latencyNanoseconds.reserveCapacity(
        max(
            0,
            configuration.requests
                - configuration.connections
        )
    )
}

for result in results {
    completedRequests +=
        result.completedRequests
    responseBodyBytes +=
        result.responseBodyBytes

    if configuration.collectLatency {
        latencyNanoseconds.append(
            contentsOf:
                result.latencyNanoseconds
        )
    }
}

let elapsedNanoseconds =
    end - start
let elapsedSeconds =
    Double(elapsedNanoseconds)
    / 1_000_000_000
let requestsPerSecond =
    Double(completedRequests)
    / elapsedSeconds
let bodyMiBPerSecond =
    (
        Double(responseBodyBytes)
        / 1_048_576
    ) / elapsedSeconds

for connection in connections {
    try? connection.channel.close().wait()
}

print("")
print("WhiteThroated Swift network benchmark client")
print(
    "target=http://"
    + configuration.host
    + ":"
    + String(configuration.port)
    + configuration.path
)
print(
    "connections="
    + String(configuration.connections)
    + " threads="
    + String(configuration.threads)
    + " latency="
    + (
        configuration.collectLatency
        ? "on"
        : "off"
    )
    + " tcp_nodelay="
    + (
        configuration.tcpNoDelay
        ? "on"
        : "off"
    )
)
print(
    "requests="
    + String(completedRequests)
    + " elapsed_s="
    + String(
        format: "%.6f",
        elapsedSeconds
    )
)
print(
    "requests_per_second="
    + String(
        format: "%.0f",
        requestsPerSecond
    )
)
print(
    "response_body_bytes="
    + String(responseBodyBytes)
)
print(
    "response_body_mib_per_second="
    + String(
        format: "%.3f",
        bodyMiBPerSecond
    )
)

if configuration.collectLatency {
    latencyNanoseconds.sort()

    if !latencyNanoseconds.isEmpty {
        let average =
            latencyNanoseconds.reduce(
                0.0
            ) {
                $0 + Double($1)
            }
            / Double(
                latencyNanoseconds.count
            )

        func percentile(
            _ percentile: Double
        ) -> Double {
            let index = Int(
                Double(
                    latencyNanoseconds.count - 1
                ) * percentile
            )

            return Double(
                latencyNanoseconds[index]
            ) / 1_000
        }

        print(
            "latency_samples="
            + String(
                latencyNanoseconds.count
            )
        )
        print(
            "latency_min_us="
            + String(
                format: "%.3f",
                Double(
                    latencyNanoseconds[0]
                ) / 1_000
            )
        )
        print(
            "latency_avg_us="
            + String(
                format: "%.3f",
                average / 1_000
            )
        )
        print(
            "latency_p50_us="
            + String(
                format: "%.3f",
                percentile(0.50)
            )
        )
        print(
            "latency_p75_us="
            + String(
                format: "%.3f",
                percentile(0.75)
            )
        )
        print(
            "latency_p90_us="
            + String(
                format: "%.3f",
                percentile(0.90)
            )
        )
        print(
            "latency_p99_us="
            + String(
                format: "%.3f",
                percentile(0.99)
            )
        )
        print(
            "latency_p99_999_us="
            + String(
                format: "%.3f",
                percentile(0.99999)
            )
        )
        print(
            "latency_max_us="
            + String(
                format: "%.3f",
                Double(
                    latencyNanoseconds[
                        latencyNanoseconds.count - 1
                    ]
                ) / 1_000
            )
        )
    }
}

print("")
