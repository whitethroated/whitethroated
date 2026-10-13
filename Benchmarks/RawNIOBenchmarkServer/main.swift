import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private final class RawBenchmarkHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let body: ByteBuffer
    private let baseHeaders: HTTPHeaders
    private var requestHead: HTTPRequestHead?

    init(allocator: ByteBufferAllocator) {
        var body = allocator.buffer(capacity: 13)
        body.writeString("Hello, World!")
        self.body = body

        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: "13"
        )
        self.baseHeaders = headers
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head

        case .body:
            break

        case .end:
            guard let requestHead else {
                return
            }

            if
                requestHead.method == .GET,
                requestHead.uri == "/plaintext"
            {
                writePlaintext(
                    requestHead: requestHead,
                    context: context
                )
            } else {
                writeNotFound(
                    requestHead: requestHead,
                    context: context
                )
            }

            self.requestHead = nil
        }
    }

    private func writePlaintext(
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        var headers = baseHeaders

        if !requestHead.isKeepAlive {
            headers.replaceOrAdd(
                name: "connection",
                value: "close"
            )
        } else if requestHead.version == .http1_0 {
            headers.replaceOrAdd(
                name: "connection",
                value: "keep-alive"
            )
        }

        let responseHead = HTTPResponseHead(
            version: requestHead.version,
            status: .ok,
            headers: headers
        )

        context.write(
            wrapOutboundOut(.head(responseHead)),
            promise: nil
        )
        context.write(
            wrapOutboundOut(.body(.byteBuffer(body))),
            promise: nil
        )
        finish(
            keepAlive: requestHead.isKeepAlive,
            context: context
        )
    }

    private func writeNotFound(
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        headers.add(
            name: "content-length",
            value: "0"
        )

        if !requestHead.isKeepAlive {
            headers.add(
                name: "connection",
                value: "close"
            )
        }

        let responseHead = HTTPResponseHead(
            version: requestHead.version,
            status: .notFound,
            headers: headers
        )

        context.write(
            wrapOutboundOut(.head(responseHead)),
            promise: nil
        )
        finish(
            keepAlive: requestHead.isKeepAlive,
            context: context
        )
    }

    private func finish(
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        context
            .writeAndFlush(wrapOutboundOut(.end(nil)))
            .whenComplete { _ in
                if !keepAlive {
                    context.close(promise: nil)
                }
            }
    }
}

let environment = ProcessInfo.processInfo.environment
let host = environment["HUDHUD_HOST"] ?? "127.0.0.1"
let port = Int(
    environment["HUDHUD_PORT"] ?? "3000"
) ?? 3000

let group = MultiThreadedEventLoopGroup(
    numberOfThreads: System.coreCount
)

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(
        ChannelOptions.backlog,
        value: 256
    )
    .serverChannelOption(
        ChannelOptions.socketOption(.so_reuseaddr),
        value: 1
    )
    .childChannelOption(
        ChannelOptions.socketOption(.tcp_nodelay),
        value: 1
    )
    .childChannelOption(
        ChannelOptions.socketOption(.so_reuseaddr),
        value: 1
    )
    .childChannelInitializer { channel in
        channel.pipeline
            .configureHTTPServerPipeline(
                withPipeliningAssistance: true,
                withErrorHandling: true
            )
            .flatMap {
                channel.pipeline.addHandler(
                    RawBenchmarkHandler(
                        allocator: channel.allocator
                    )
                )
            }
    }

do {
    let channel = try bootstrap
        .bind(host: host, port: port)
        .wait()

    try channel.closeFuture.wait()
    try group.syncShutdownGracefully()
} catch {
    try? group.syncShutdownGracefully()
    throw error
}
