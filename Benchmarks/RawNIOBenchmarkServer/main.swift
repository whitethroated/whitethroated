import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private final class RawBenchmarkHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let allocator: ByteBufferAllocator
    private let body: ByteBuffer
    private let baseHeaders: HTTPHeaders
    private let http11Head: HTTPResponseHead
    private let emptyHeaders: HTTPHeaders
    private let emptyHTTP11Head: HTTPResponseHead
    private var requestHead: HTTPRequestHead?

    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator

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
        headers.add(
            name: "date",
            value: "Thu, 01 Jan 1970 00:00:00 GMT"
        )
        self.baseHeaders = headers
        self.http11Head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: headers
        )

        var emptyHeaders = HTTPHeaders()
        emptyHeaders.add(
            name: "content-length",
            value: "0"
        )
        self.emptyHeaders = emptyHeaders
        self.emptyHTTP11Head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: emptyHeaders
        )
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            if requestBodyIsDefinitelyEmpty(head) {
                writeResponse(
                    requestHead: head,
                    context: context
                )
            } else {
                requestHead = head
            }

        case .body(_):
            break

        case .end:
            guard let requestHead else {
                return
            }

            writeResponse(
                requestHead: requestHead,
                context: context
            )
            self.requestHead = nil
        }
    }

    @inline(__always)
    private func writeResponse(
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        switch requestHead.method {
        case .GET:
            if requestHead.uri == "/prepared" {
                writePlaintext(
                    requestHead: requestHead,
                    context: context
                )
                return
            }

            if requestHead.uri == "/" {
                writeEmptyOK(
                    requestHead: requestHead,
                    context: context
                )
                return
            }

            if requestHead.uri.hasPrefix("/user/") {
                writeUserParameter(
                    requestHead: requestHead,
                    context: context
                )
                return
            }

        case .POST:
            if requestHead.uri == "/user" {
                writeEmptyOK(
                    requestHead: requestHead,
                    context: context
                )
                return
            }

        default:
            break
        }

        writeNotFound(
            requestHead: requestHead,
            context: context
        )
    }

    @inline(__always)
    private func requestBodyIsDefinitelyEmpty(
        _ head: HTTPRequestHead
    ) -> Bool {
        guard head.headers.first(
            name: "transfer-encoding"
        ) == nil else {
            return false
        }

        guard let contentLength = head.headers.first(
            name: "content-length"
        ) else {
            return true
        }

        return contentLength == "0"
    }

    @inline(__always)
    private func requestIsKeepAlive(
        _ head: HTTPRequestHead
    ) -> Bool {
        guard head.headers.first(
            name: "connection"
        ) != nil else {
            return
                head.version.major == 1
                && head.version.minor >= 1
        }

        return head.isKeepAlive
    }

    @inline(__always)
    private func writePlaintext(
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        if
            requestHead.version == .http1_1,
            requestIsKeepAlive(requestHead)
        {
            context.write(
                wrapOutboundOut(.head(http11Head)),
                promise: nil
            )
            context.write(
                wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )
            return
        }

        var headers = baseHeaders

        if !requestIsKeepAlive(requestHead) {
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
            keepAlive: requestIsKeepAlive(requestHead),
            context: context
        )
    }

    @inline(__always)
    private func writeEmptyOK(
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let keepAlive =
            requestIsKeepAlive(requestHead)

        if
            requestHead.version == .http1_1,
            keepAlive
        {
            context.write(
                wrapOutboundOut(
                    .head(emptyHTTP11Head)
                ),
                promise: nil
            )
            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )
            return
        }

        var headers = emptyHeaders

        if !keepAlive {
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

        context.write(
            wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: requestHead.version,
                        status: .ok,
                        headers: headers
                    )
                )
            ),
            promise: nil
        )
        finish(
            keepAlive: keepAlive,
            context: context
        )
    }

    @inline(__always)
    private func writeUserParameter(
        requestHead: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        let prefixLength = 6
        let bytes = requestHead.uri.utf8

        guard bytes.count > prefixLength else {
            writeNotFound(
                requestHead: requestHead,
                context: context
            )
            return
        }

        let parameterStart = bytes.index(
            bytes.startIndex,
            offsetBy: prefixLength
        )
        let parameterBytes =
            bytes[parameterStart...]

        guard
            !parameterBytes.isEmpty,
            !parameterBytes.contains(47),
            !parameterBytes.contains(63)
        else {
            writeNotFound(
                requestHead: requestHead,
                context: context
            )
            return
        }

        var parameterBody = allocator.buffer(
            capacity: parameterBytes.count
        )
        parameterBody.writeBytes(parameterBytes)

        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: String(parameterBody.readableBytes)
        )

        let keepAlive =
            requestIsKeepAlive(requestHead)

        if !keepAlive {
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

        context.write(
            wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: requestHead.version,
                        status: .ok,
                        headers: headers
                    )
                )
            ),
            promise: nil
        )
        context.write(
            wrapOutboundOut(
                .body(
                    .byteBuffer(parameterBody)
                )
            ),
            promise: nil
        )
        finish(
            keepAlive: keepAlive,
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

        if !requestIsKeepAlive(requestHead) {
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
            keepAlive: requestIsKeepAlive(requestHead),
            context: context
        )
    }

    private func finish(
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        context
            .writeAndFlush(wrapOutboundOut(.end(nil)))
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { _ in
                if !keepAlive {
                    context.close(promise: nil)
                }
            }
    }
}

let environment = ProcessInfo.processInfo.environment
let host = environment["WHITETHROATED_HOST"] ?? "127.0.0.1"
let port = Int(
    environment["WHITETHROATED_PORT"] ?? "3000"
) ?? 3000

let eventLoopThreads = Int(
    environment["WHITETHROATED_THREADS"] ?? ""
) ?? System.coreCount

let group = MultiThreadedEventLoopGroup(
    numberOfThreads: eventLoopThreads
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
        ChannelOptions.socketOption(.so_reuseaddr),
        value: 1
    )
    .childChannelInitializer { channel in
        channel.setOption(
            ChannelOptions.socketOption(.tcp_nodelay),
            value: 1
        )
        .flatMapError { _ in
            channel.eventLoop
                .makeSucceededVoidFuture()
        }
        .flatMap {
            channel.pipeline
                .configureHTTPServerPipeline(
                    withPipeliningAssistance: true,
                    withErrorHandling: true
                )
        }
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
