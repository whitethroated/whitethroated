import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private final class RawBenchmarkHandler: ChannelInboundHandler, @unchecked Sendable {
    private static let parameterHeaderCacheLimit = 64

    private static let parameterHeaderCache: [HTTPHeaders] =
        (0...parameterHeaderCacheLimit).map {
            makeParameterHeaders(length: $0)
        }

    private static func makeParameterHeaders(
        length: Int
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: String(length)
        )
        return headers
    }

    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let allocator: ByteBufferAllocator
    private let body: ByteBuffer
    private let baseHeaders: HTTPHeaders
    private let http11Head: HTTPResponseHead
    private let emptyHeaders: HTTPHeaders
    private let emptyHTTP11Head: HTTPResponseHead
    private let jsonBody: ByteBuffer
    private let jsonBaseHeaders: HTTPHeaders
    private let jsonHTTP11Head: HTTPResponseHead
    private let dynamicHTTP11HeadTemplate =
        HTTPResponseHead(
            version: .http1_1,
            status: .ok
        )
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

        var jsonBody = allocator.buffer(capacity: 27)
        jsonBody.writeString(#"{"message":"Hello, World!"}"#)
        self.jsonBody = jsonBody

        var jsonHeaders = HTTPHeaders()
        jsonHeaders.add(
            name: "content-type",
            value: "application/json; charset=utf-8"
        )
        jsonHeaders.add(
            name: "content-length",
            value: "27"
        )
        self.jsonBaseHeaders = jsonHeaders
        self.jsonHTTP11Head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: jsonHeaders
        )
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            let minimalHTTP11 =
                requestHasMinimalHTTP11Headers(
                    head
                )

            if
                minimalHTTP11
                || requestBodyIsDefinitelyEmpty(
                    head
                )
            {
                writeResponse(
                    requestHead: head,
                    minimalHTTP11:
                        minimalHTTP11,
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
                minimalHTTP11: false,
                context: context
            )
            self.requestHead = nil
        }
    }

    @inline(__always)
    private func writeResponse(
        requestHead: HTTPRequestHead,
        minimalHTTP11: Bool,
        context: ChannelHandlerContext
    ) {
        switch requestHead.method {
        case .GET:
            if requestHead.uri == "/prepared" {
                writePlaintext(
                    requestHead: requestHead,
                    minimalHTTP11:
                        minimalHTTP11,
                    context: context
                )
                return
            }

            if requestHead.uri == "/" {
                writeEmptyOK(
                    requestHead: requestHead,
                    minimalHTTP11:
                        minimalHTTP11,
                    context: context
                )
                return
            }

            if requestHead.uri == "/json" {
                writeJSON(
                    requestHead: requestHead,
                    minimalHTTP11:
                        minimalHTTP11,
                    context: context
                )
                return
            }

            if requestHead.uri.hasPrefix("/user/") {
                writeUserParameter(
                    requestHead: requestHead,
                    minimalHTTP11:
                        minimalHTTP11,
                    context: context
                )
                return
            }

        case .POST:
            if requestHead.uri == "/user" {
                writeEmptyOK(
                    requestHead: requestHead,
                    minimalHTTP11:
                        minimalHTTP11,
                    context: context
                )
                return
            }

        default:
            break
        }

        writeNotFound(
            requestHead: requestHead,
            minimalHTTP11:
                minimalHTTP11,
            context: context
        )
    }

    @inline(__always)
    private func requestHasMinimalHTTP11Headers(
        _ head: HTTPRequestHead
    ) -> Bool {
        guard head.version == .http1_1 else {
            return false
        }

        switch head.headers.count {
        case 0:
            return true

        case 1:
            guard let header = head.headers.first else {
                return false
            }

            return isHostHeaderName(
                header.name
            )

        default:
            return false
        }
    }

    @inline(__always)
    private func isHostHeaderName(
        _ name: String
    ) -> Bool {
        let bytes = name.utf8

        guard bytes.count == 4 else {
            return false
        }

        var index = bytes.startIndex
        let h = foldedASCIILowercase(
            bytes[index]
        )
        bytes.formIndex(after: &index)
        let o = foldedASCIILowercase(
            bytes[index]
        )
        bytes.formIndex(after: &index)
        let s = foldedASCIILowercase(
            bytes[index]
        )
        bytes.formIndex(after: &index)
        let t = foldedASCIILowercase(
            bytes[index]
        )

        return
            h == 104
            && o == 111
            && s == 115
            && t == 116
    }

    @inline(__always)
    private func foldedASCIILowercase(
        _ byte: UInt8
    ) -> UInt8 {
        byte >= 65 && byte <= 90
            ? byte + 32
            : byte
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
        minimalHTTP11: Bool,
        context: ChannelHandlerContext
    ) {
        if minimalHTTP11 {
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
    private func writeJSON(
        requestHead: HTTPRequestHead,
        minimalHTTP11: Bool,
        context: ChannelHandlerContext
    ) {
        if minimalHTTP11 {
            context.write(
                wrapOutboundOut(.head(jsonHTTP11Head)),
                promise: nil
            )
            context.write(
                wrapOutboundOut(.body(.byteBuffer(jsonBody))),
                promise: nil
            )
            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )
            return
        }

        if
            requestHead.version == .http1_1,
            requestIsKeepAlive(requestHead)
        {
            context.write(
                wrapOutboundOut(.head(jsonHTTP11Head)),
                promise: nil
            )
            context.write(
                wrapOutboundOut(.body(.byteBuffer(jsonBody))),
                promise: nil
            )
            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )
            return
        }

        var headers = jsonBaseHeaders

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
            wrapOutboundOut(.body(.byteBuffer(jsonBody))),
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
        minimalHTTP11: Bool,
        context: ChannelHandlerContext
    ) {
        let keepAlive =
            minimalHTTP11
            || requestIsKeepAlive(
                requestHead
            )

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
        minimalHTTP11: Bool,
        context: ChannelHandlerContext
    ) {
        let prefixLength = 6
        let bytes = requestHead.uri.utf8

        guard bytes.count > prefixLength else {
            writeNotFound(
                requestHead: requestHead,
                minimalHTTP11:
                    minimalHTTP11,
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

        guard !parameterBytes.isEmpty else {
            writeNotFound(
                requestHead: requestHead,
                minimalHTTP11:
                    minimalHTTP11,
                context: context
            )
            return
        }

        for byte in parameterBytes {
            if byte == 47 || byte == 63 {
                writeNotFound(
                    requestHead: requestHead,
                    minimalHTTP11:
                        minimalHTTP11,
                    context: context
                )
                return
            }
        }

        let parameterLength =
            parameterBytes.count

        var parameterBody = allocator.buffer(
            capacity: parameterLength
        )
        parameterBody.writeBytes(parameterBytes)

        var headers: HTTPHeaders

        if
            parameterLength
            <= Self.parameterHeaderCacheLimit
        {
            headers =
                Self.parameterHeaderCache[
                    parameterLength
                ]
        } else {
            headers =
                Self.makeParameterHeaders(
                    length: parameterLength
                )
        }

        let keepAlive =
            minimalHTTP11
            || requestIsKeepAlive(
                requestHead
            )

        if
            requestHead.version == .http1_1,
            keepAlive
        {
            var responseHead =
                dynamicHTTP11HeadTemplate
            responseHead.headers = headers

            context.write(
                wrapOutboundOut(
                    .head(responseHead)
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
            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )
            return
        }

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
        minimalHTTP11: Bool,
        context: ChannelHandlerContext
    ) {
        var headers = HTTPHeaders()
        headers.add(
            name: "content-length",
            value: "0"
        )

        let keepAlive =
            minimalHTTP11
            || requestIsKeepAlive(
                requestHead
            )

        if !keepAlive {
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
            keepAlive: keepAlive,
            context: context
        )
    }

    private func finish(
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        if keepAlive {
            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )
            return
        }

        context
            .writeAndFlush(
                wrapOutboundOut(.end(nil))
            )
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { _ in
                context.close(promise: nil)
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
