import NIOCore
import NIOHTTP1

final class HTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let application: Application
    private let maxRequestBodyBytes: Int
    private let emptyBody = ByteBufferAllocator().buffer(
        capacity: 0
    )

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var receivedBodyBytes = 0
    private var requestBodyTooLarge = false

    init(
        application: Application,
        maxRequestBodyBytes: Int? = nil
    ) {
        self.application = application
        self.maxRequestBodyBytes =
            maxRequestBodyBytes
            ?? application.configuration.maxRequestBodyBytes
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            requestBody = nil
            receivedBodyBytes = 0
            requestBodyTooLarge =
                declaredBodyExceedsLimit(head)

        case .body(var body):
            guard !requestBodyTooLarge else {
                return
            }

            let chunkBytes = body.readableBytes

            if chunkBytes > maxRequestBodyBytes - receivedBodyBytes {
                requestBody = nil
                requestBodyTooLarge = true
                return
            }

            receivedBodyBytes += chunkBytes

            if requestBody == nil {
                requestBody = body
            } else {
                requestBody?.writeBuffer(&body)
            }

        case .end:
            guard let head = requestHead else {
                return
            }

            let keepAlive = head.isKeepAlive
            let version = head.version
            let isHead = head.method == .HEAD

            if requestBodyTooLarge {
                write(
                    .payloadTooLarge(),
                    isHeadRequest: isHead,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )
                resetRequestState()
                return
            }

            switch application.respondTransport(
                head: head,
                body: requestBody ?? emptyBody,
                on: context.eventLoop
            ) {
            case .immediate(let response):
                write(
                    response,
                    isHeadRequest: isHead,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )

            case .prepared(let prepared):
                writePrepared(
                    prepared,
                    isHeadRequest: isHead,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )

            case .future(let future):
                future.whenComplete { result in
                    switch result {
                    case .success(let response):
                        self.write(
                            response,
                            isHeadRequest: isHead,
                            version: version,
                            keepAlive: keepAlive,
                            context: context
                        )

                    case .failure:
                        self.write(
                            .internalServerError(),
                            isHeadRequest: isHead,
                            version: version,
                            keepAlive: keepAlive,
                            context: context
                        )
                    }
                }
            }

            resetRequestState()
        }
    }

    @inline(__always)
    private func declaredBodyExceedsLimit(
        _ head: HTTPRequestHead
    ) -> Bool {
        switch head.method {
        case .POST, .PUT, .PATCH, .DELETE:
            break

        default:
            return false
        }

        guard
            let value = head.headers.first(
                name: "content-length"
            ),
            let contentLength = Int(value)
        else {
            return false
        }

        return contentLength > maxRequestBodyBytes
    }

    private func resetRequestState() {
        requestHead = nil
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
    }

    @inline(__always)
    private func writePrepared(
        _ prepared: PreparedResponse,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        guard
            version == .http1_1,
            keepAlive
        else {
            write(
                prepared.response,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            return
        }

        context.write(
            wrapOutboundOut(.head(prepared.http11Head)),
            promise: nil
        )

        if
            !isHeadRequest,
            let body = prepared.bodyBuffer,
            body.readableBytes > 0
        {
            context.write(
                wrapOutboundOut(.body(.byteBuffer(body))),
                promise: nil
            )
        }

        context.writeAndFlush(
            wrapOutboundOut(.end(nil)),
            promise: nil
        )
    }

    private func write(
        _ response: Response,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        var headers = response.headers
        let buffer: ByteBuffer?

        switch response.body {
        case .empty:
            buffer = nil

        case .text(let value):
            var valueBuffer = context.channel.allocator.buffer(
                capacity: value.utf8.count
            )
            valueBuffer.writeString(value)
            buffer = valueBuffer

        case .bytes(let bytes):
            var valueBuffer = context.channel.allocator.buffer(
                capacity: bytes.count
            )
            valueBuffer.writeBytes(bytes)
            buffer = valueBuffer

        case .buffer(let value):
            buffer = value
        }

        if headers.first(name: "content-length") == nil {
            headers.add(
                name: "content-length",
                value: String(buffer?.readableBytes ?? 0)
            )
        }

        if !keepAlive {
            headers.replaceOrAdd(
                name: "connection",
                value: "close"
            )
        } else if version == .http1_0 {
            headers.replaceOrAdd(
                name: "connection",
                value: "keep-alive"
            )
        }

        let head = HTTPResponseHead(
            version: version,
            status: response.status,
            headers: headers
        )

        context.write(
            wrapOutboundOut(.head(head)),
            promise: nil
        )

        if
            !isHeadRequest,
            let buffer,
            buffer.readableBytes > 0
        {
            context.write(
                wrapOutboundOut(.body(.byteBuffer(buffer))),
                promise: nil
            )
        }

        context
            .writeAndFlush(wrapOutboundOut(.end(nil)))
            .whenComplete { _ in
                if !keepAlive {
                    context.close(promise: nil)
                }
            }
    }
}
