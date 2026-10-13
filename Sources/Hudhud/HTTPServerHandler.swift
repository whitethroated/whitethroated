import NIOCore
import NIOHTTP1

final class HTTPServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let application: Application
    private let maxRequestBodyBytes: Int

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
            requestBodyTooLarge = false

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
            let method = HTTPMethod(head.method)

            if requestBodyTooLarge {
                write(
                    .payloadTooLarge(),
                    requestMethod: method,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )
                resetRequestState()
                return
            }

            let body = requestBody
                ?? context.channel.allocator.buffer(capacity: 0)

            let request = Request(
                head: head,
                body: body
            )

            switch application.respondFast(
                to: request,
                on: context.eventLoop
            ) {
            case .immediate(let response):
                write(
                    response,
                    requestMethod: method,
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
                            requestMethod: method,
                            version: version,
                            keepAlive: keepAlive,
                            context: context
                        )

                    case .failure:
                        self.write(
                            .internalServerError(),
                            requestMethod: method,
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

    private func resetRequestState() {
        requestHead = nil
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
    }

    private func write(
        _ response: Response,
        requestMethod: HTTPMethod,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        var headers = response.headers
        let buffer: ByteBuffer

        switch response.body {
        case .empty:
            buffer = context.channel.allocator.buffer(
                capacity: 0
            )

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
                value: String(buffer.readableBytes)
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
            requestMethod != .head,
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
