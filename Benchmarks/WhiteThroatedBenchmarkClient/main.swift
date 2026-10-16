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

        return BenchmarkConfiguration(
            host: host,
            port: port,
            path: path,
            connections: connections,
            requests: requests,
            threads: threads
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
    case connectionClosed
    case unexpectedStatus(UInt)

    var description: String {
        switch self {
        case .connectionClosed:
            return "connection closed before benchmark completion"

        case .unexpectedStatus(let status):
            return "unexpected HTTP status \(status)"
        }
    }
}

private final class BenchmarkClientHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let requestHead: HTTPRequestHead
    private let targetRequests: Int
    private let donePromise: EventLoopPromise<Int>

    private var completedRequests = 0
    private var finished = false

    init(
        requestHead: HTTPRequestHead,
        targetRequests: Int,
        donePromise: EventLoopPromise<Int>
    ) {
        self.requestHead = requestHead
        self.targetRequests = targetRequests
        self.donePromise = donePromise
    }

    func wait() throws -> Int {
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

        case .body:
            break

        case .end:
            guard !finished else {
                return
            }

            completedRequests += 1

            if completedRequests >= targetRequests {
                finished = true
                donePromise.succeed(
                    completedRequests
                )
                return
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
            BenchmarkClientError.connectionClosed,
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
            of: Int.self
        )

    let handler = BenchmarkClientHandler(
        requestHead: requestHead,
        targetRequests: targetRequests,
        donePromise: donePromise
    )

    let bootstrap = ClientBootstrap(
        group: group
    )
    .channelOption(
        ChannelOptions.socketOption(
            .tcp_nodelay
        ),
        value: 1
    )
    .channelInitializer { channel in
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

var completedRequests = 0

for connection in connections {
    completedRequests +=
        try connection.handler.wait()
}

let end =
    DispatchTime.now()
        .uptimeNanoseconds

let elapsedNanoseconds =
    end - start
let elapsedSeconds =
    Double(elapsedNanoseconds)
    / 1_000_000_000
let requestsPerSecond =
    Double(completedRequests)
    / elapsedSeconds

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
print("")
