import Dispatch
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

private struct Configuration {
    let host: String
    let port: Int
    let path: String
    let connections: Int
    let messages: Int
    let warmupMessages: Int
    let threads: Int
    let payloadBytes: Int
    let collectLatency: Bool

    static func load() -> Configuration {
        let env =
            ProcessInfo.processInfo
                .environment

        func positive(
            _ name: String,
            _ fallback: Int
        ) -> Int {
            guard
                let raw = env[name],
                let value = Int(raw),
                value > 0
            else {
                return fallback
            }

            return value
        }

        let path =
            env[
                "WHITETHROATED_WS_BENCH_PATH"
            ] ?? "/websocket"
        let messages =
            positive(
                "WHITETHROATED_WS_BENCH_MESSAGES",
                1_000_000
            )
        let requestedConnections =
            positive(
                "WHITETHROATED_WS_BENCH_CONNECTIONS",
                128
            )
        let connections =
            min(
                requestedConnections,
                messages
            )

        return Configuration(
            host:
                env[
                    "WHITETHROATED_WS_BENCH_HOST"
                ] ?? "127.0.0.1",
            port:
                positive(
                    "WHITETHROATED_WS_BENCH_PORT",
                    3000
                ),
            path:
                path.hasPrefix("/")
                ? path
                : "/" + path,
            connections:
                connections,
            messages:
                messages,
            warmupMessages:
                positive(
                    "WHITETHROATED_WS_BENCH_WARMUP_PER_CONNECTION",
                    100
                ),
            threads:
                positive(
                    "WHITETHROATED_WS_BENCH_THREADS",
                    System.coreCount
                ),
            payloadBytes:
                positive(
                    "WHITETHROATED_WS_BENCH_PAYLOAD_BYTES",
                    32
                ),
            collectLatency:
                env[
                    "WHITETHROATED_WS_BENCH_LATENCY"
                ] == "1"
        )
    }
}

private enum ClientError:
    Error,
    CustomStringConvertible
{
    case closed
    case unexpectedOpcode
    case unexpectedPayloadSize(
        expected: Int,
        actual: Int
    )

    var description: String {
        switch self {
        case .closed:
            return "WebSocket connection closed before the benchmark completed"
        case .unexpectedOpcode:
            return "WebSocket benchmark expected a binary echo"
        case .unexpectedPayloadSize(
            let expected,
            let actual
        ):
            return "WebSocket payload size mismatch: expected \(expected), got \(actual)"
        }
    }
}

private struct ConnectionResult {
    let messages: Int
    let bytes: Int
    let latencyNanoseconds:
        [UInt64]
}

private final class EchoHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn =
        WebSocketFrame

    private enum Phase {
        case idle
        case warmup
        case measured
        case finished
    }

    private let payload: ByteBuffer
    private let warmupTarget: Int
    private let measuredTarget: Int
    private let collectLatency: Bool
    private let warmupPromise:
        EventLoopPromise<Void>
    private let measuredPromise:
        EventLoopPromise<
            ConnectionResult
        >

    private var phase:
        Phase = .idle
    private var completed = 0
    private var bytes = 0
    private var startedAt: UInt64?
    private var latency:
        [UInt64] = []

    init(
        payload: ByteBuffer,
        warmupTarget: Int,
        measuredTarget: Int,
        collectLatency: Bool,
        warmupPromise:
            EventLoopPromise<Void>,
        measuredPromise:
            EventLoopPromise<
                ConnectionResult
            >
    ) {
        self.payload = payload
        self.warmupTarget =
            warmupTarget
        self.measuredTarget =
            measuredTarget
        self.collectLatency =
            collectLatency
        self.warmupPromise =
            warmupPromise
        self.measuredPromise =
            measuredPromise

        if collectLatency {
            latency.reserveCapacity(
                measuredTarget
            )
        }
    }

    func startWarmup(
        channel: Channel
    ) {
        channel.eventLoop.execute {
            self.phase = .warmup
            self.completed = 0
            self.send(channel)
        }
    }

    func startMeasured(
        channel: Channel
    ) {
        channel.eventLoop.execute {
            self.phase = .measured
            self.completed = 0
            self.bytes = 0
            self.latency.removeAll(
                keepingCapacity: true
            )
            self.send(channel)
        }
    }

    func channelRead(
        context:
            ChannelHandlerContext,
        data: NIOAny
    ) {
        let frame =
            unwrapInboundIn(data)

        guard
            frame.opcode == .binary
        else {
            fail(
                ClientError
                    .unexpectedOpcode,
                context: context
            )
            return
        }

        let readable =
            frame.unmaskedData
                .readableBytes

        guard
            readable
                == payload
                    .readableBytes
        else {
            fail(
                ClientError
                    .unexpectedPayloadSize(
                        expected:
                            payload
                                .readableBytes,
                        actual: readable
                    ),
                context: context
            )
            return
        }

        if
            phase == .measured,
            collectLatency,
            let startedAt
        {
            latency.append(
                DispatchTime.now()
                    .uptimeNanoseconds
                    - startedAt
            )
        }

        completed += 1

        switch phase {
        case .warmup:
            if completed
                >= warmupTarget
            {
                phase = .idle
                warmupPromise
                    .succeed(())
            } else {
                send(
                    context.channel
                )
            }

        case .measured:
            bytes += readable

            if completed
                >= measuredTarget
            {
                phase = .finished
                measuredPromise.succeed(
                    ConnectionResult(
                        messages:
                            completed,
                        bytes: bytes,
                        latencyNanoseconds:
                            latency
                    )
                )
            } else {
                send(
                    context.channel
                )
            }

        case .idle,
             .finished:
            break
        }
    }

    func channelInactive(
        context:
            ChannelHandlerContext
    ) {
        fail(
            ClientError.closed,
            context: context
        )
    }

    func errorCaught(
        context:
            ChannelHandlerContext,
        error: Error
    ) {
        fail(
            error,
            context: context
        )
    }

    private func send(
        _ channel: Channel
    ) {
        if
            phase == .measured,
            collectLatency
        {
            startedAt =
                DispatchTime.now()
                    .uptimeNanoseconds
        }

        channel.writeAndFlush(
            WebSocketFrame(
                fin: true,
                opcode: .binary,
                data: payload
            ),
            promise: nil
        )
    }

    private func fail(
        _ error: Error,
        context:
            ChannelHandlerContext
    ) {
        switch phase {
        case .warmup:
            warmupPromise
                .fail(error)
        case .measured:
            measuredPromise
                .fail(error)
        case .idle,
             .finished:
            break
        }

        phase = .finished
        context.close(
            promise: nil
        )
    }
}

private struct Connection {
    let channel: Channel
    let handler: EchoHandler
    let warmup:
        EventLoopFuture<Void>
    let measured:
        EventLoopFuture<
            ConnectionResult
        >
}

private let configuration =
    Configuration.load()
let group =
    MultiThreadedEventLoopGroup(
        numberOfThreads:
            configuration.threads
    )

defer {
    try? group
        .syncShutdownGracefully()
}

let baseMessages =
    configuration.messages
    / configuration.connections
let extras =
    configuration.messages
    % configuration.connections

private var connections: [Connection] = []
connections.reserveCapacity(
    configuration.connections
)

for index in
    0..<configuration.connections
{
    let eventLoop = group.next()
    let warmupPromise =
        eventLoop.makePromise(
            of: Void.self
        )
    let measuredPromise =
        eventLoop.makePromise(
            of:
                ConnectionResult.self
        )

    var payload =
        ByteBufferAllocator()
            .buffer(
                capacity:
                    configuration
                        .payloadBytes
            )
    payload.writeRepeatingByte(
        97,
        count:
            configuration
                .payloadBytes
    )

    let target =
        baseMessages
        + (
            index < extras
            ? 1
            : 0
        )
    let handler =
        EchoHandler(
            payload: payload,
            warmupTarget:
                configuration
                    .warmupMessages,
            measuredTarget:
                target,
            collectLatency:
                configuration
                    .collectLatency,
            warmupPromise:
                warmupPromise,
            measuredPromise:
                measuredPromise
        )
    let upgraded =
        eventLoop.makePromise(
            of: Void.self
        )
    let upgrader =
        NIOWebSocketClientUpgrader {
            channel,
            _ in

            channel.pipeline
                .addHandler(
                    handler
                )
                .map {
                    upgraded.succeed(())
                }
        }

    let upgrade:
        NIOHTTPClientUpgradeSendableConfiguration =
            (
                upgraders: [
                    upgrader,
                ],
                completionHandler: {
                    _ in
                }
            )
    let bootstrap =
        ClientBootstrap(
            group: eventLoop
        )
        .channelOption(
            ChannelOptions
                .tcpOption(
                    .tcp_nodelay
                ),
            value: 1
        )
        .channelInitializer {
            channel in

            channel.eventLoop
                .makeCompletedFuture {
                    try channel.pipeline
                        .syncOperations
                        .addHTTPClientHandlers(
                            withClientUpgrade:
                                upgrade
                        )
                }
        }

    let channel =
        try bootstrap.connect(
            host:
                configuration.host,
            port:
                configuration.port
        )
        .wait()

    var head =
        HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: configuration.path
        )
    head.headers.add(
        name: "host",
        value:
            configuration.host
            + ":"
            + String(
                configuration.port
            )
    )
    head.headers.add(
        name: "connection",
        value: "upgrade"
    )
    head.headers.add(
        name: "upgrade",
        value: "websocket"
    )

    channel.write(
        HTTPClientRequestPart
            .head(head),
        promise: nil
    )
    channel.writeAndFlush(
        HTTPClientRequestPart
            .end(nil),
        promise: nil
    )

    try upgraded.futureResult
        .wait()

    connections.append(
        Connection(
            channel: channel,
            handler: handler,
            warmup:
                warmupPromise
                    .futureResult,
            measured:
                measuredPromise
                    .futureResult
        )
    )
}

for connection in connections {
    connection.handler
        .startWarmup(
            channel:
                connection.channel
        )
}

for connection in connections {
    try connection.warmup.wait()
}

let start =
    DispatchTime.now()
        .uptimeNanoseconds

for connection in connections {
    connection.handler
        .startMeasured(
            channel:
                connection.channel
        )
}

private var results:
    [ConnectionResult] = []
results.reserveCapacity(
    connections.count
)

for connection in connections {
    results.append(
        try connection.measured.wait()
    )
}

let end =
    DispatchTime.now()
        .uptimeNanoseconds

var completed = 0
var bytes = 0
var latency:
    [UInt64] = []

if configuration.collectLatency {
    latency.reserveCapacity(
        configuration.messages
    )
}

for result in results {
    completed += result.messages
    bytes += result.bytes

    if configuration.collectLatency {
        latency.append(
            contentsOf:
                result
                    .latencyNanoseconds
        )
    }
}

for connection in connections {
    try? connection.channel
        .close()
        .wait()
}

let elapsed =
    Double(end - start)
    / 1_000_000_000
let throughput =
    Double(completed)
    / elapsed
let mibPerSecond =
    (
        Double(bytes)
        / 1_048_576
    )
    / elapsed

print(
    "WhiteThroated WebSocket benchmark client"
)
print(
    "connections="
    + String(
        configuration.connections
    )
    + " threads="
    + String(
        configuration.threads
    )
    + " payload_bytes="
    + String(
        configuration.payloadBytes
    )
)
print(
    "warmup_per_connection="
    + String(
        configuration.warmupMessages
    )
    + " messages="
    + String(completed)
    + " elapsed_s="
    + String(
        format: "%.6f",
        elapsed
    )
)
print(
    "messages_per_second="
    + String(
        format: "%.0f",
        throughput
    )
)
print(
    "payload_mib_per_second="
    + String(
        format: "%.3f",
        mibPerSecond
    )
)

if configuration.collectLatency {
    latency.sort()

    if !latency.isEmpty {
        func percentile(
            _ p: Double
        ) -> Double {
            let index =
                Int(
                    Double(
                        latency.count - 1
                    )
                    * p
                )

            return Double(
                latency[index]
            ) / 1_000
        }

        print(
            "latency_samples="
            + String(latency.count)
        )
        print(
            "latency_p50_us="
            + String(
                format: "%.3f",
                percentile(0.50)
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
                    latency[
                        latency.count - 1
                    ]
                ) / 1_000
            )
        )
    }
}
