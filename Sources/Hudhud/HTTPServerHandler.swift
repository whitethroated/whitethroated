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

    private var streamingStart: StreamingTransportStart?
    private var streamingPendingChunks: [ByteBuffer] = []
    private var streamingChunkFuture:
        EventLoopFuture<Void>?
    private var streamingEndReceived = false
    private var streamingReadsPaused = false
    private var streamingFailure: Error?

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
            beginRequest(
                head,
                context: context
            )

        case .body(let body):
            receiveBody(
                body,
                context: context
            )

        case .end:
            finishRequest(
                context: context
            )
        }
    }

    func channelInactive(
        context: ChannelHandlerContext
    ) {
        streamingStart?.registration.cancel(
            BodyStreamError.connectionClosed
        )
        resetStreamingState()
        streamingReadsPaused = false
        context.fireChannelInactive()
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        streamingStart?.registration.cancel(error)
        resetStreamingState()
        streamingReadsPaused = false
        context.close(promise: nil)
    }

    private func beginRequest(
        _ head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        requestHead = head
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
        streamingFailure = nil
        streamingEndReceived = false
        streamingPendingChunks.removeAll(
            keepingCapacity: true
        )
        streamingChunkFuture = nil

        if
            application.hasStreamingRoute(
                for: head.method
            ),
            let start = application
            .beginStreamingTransport(
                head: head,
                emptyBody: emptyBody,
                on: context.eventLoop
            )
        {
            streamingStart = start
            requestBodyTooLarge =
                declaredBodyExceedsLimit(
                    head,
                    maxBodyBytes:
                        start.maxBodyBytes
                )

            if requestBodyTooLarge {
                start.registration.cancel(
                    BodyStreamError.payloadTooLarge
                )
            }

            observeStreamingRegistration(
                start.registration,
                context: context
            )
            return
        }

        streamingStart = nil
        requestBodyTooLarge =
            declaredBodyExceedsLimit(
                head,
                maxBodyBytes:
                    maxRequestBodyBytes
            )
    }

    private func receiveBody(
        _ body: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        guard !requestBodyTooLarge else {
            return
        }

        let maxBodyBytes =
            streamingStart?.maxBodyBytes
            ?? maxRequestBodyBytes
        let chunkBytes = body.readableBytes

        if
            chunkBytes
            > maxBodyBytes - receivedBodyBytes
        {
            requestBody = nil
            requestBodyTooLarge = true

            if let start = streamingStart {
                streamingPendingChunks.removeAll(
                    keepingCapacity: true
                )
                start.registration.cancel(
                    BodyStreamError.payloadTooLarge
                )
                resumeStreamingReads(
                    context: context
                )
            }

            return
        }

        receivedBodyBytes += chunkBytes

        guard let start = streamingStart else {
            appendAggregatedBody(body)
            return
        }

        receiveStreamingBody(
            body,
            start: start,
            context: context
        )
    }

    private func finishRequest(
        context: ChannelHandlerContext
    ) {
        guard let head = requestHead else {
            return
        }

        if streamingStart != nil {
            streamingEndReceived = true
            finalizeStreamingIfReady(
                context: context
            )
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

        let result = application.respondTransport(
            head: head,
            body: requestBody ?? emptyBody,
            on: context.eventLoop
        )

        write(
            result,
            isHeadRequest: isHead,
            version: version,
            keepAlive: keepAlive,
            context: context
        )
        resetRequestState()
    }

    @inline(__always)
    private func appendAggregatedBody(
        _ body: ByteBuffer
    ) {
        if requestBody == nil {
            requestBody = body
            return
        }

        var body = body
        requestBody?.writeBuffer(&body)
    }

    private func receiveStreamingBody(
        _ body: ByteBuffer,
        start: StreamingTransportStart,
        context: ChannelHandlerContext
    ) {
        guard streamingFailure == nil else {
            return
        }

        guard streamingChunkFuture == nil else {
            streamingPendingChunks.append(body)
            return
        }

        switch start.registration.currentState {
        case .pending:
            streamingPendingChunks.append(body)
            pauseStreamingReads(
                context: context
            )

        case .bypass:
            break

        case .cancelled(_):
            break

        case .session(let session):
            consumeStreamingChunk(
                body,
                session: session,
                start: start,
                context: context
            )
        }
    }

    private func consumeStreamingChunk(
        _ body: ByteBuffer,
        session: BodyStreamSession,
        start: StreamingTransportStart,
        context: ChannelHandlerContext
    ) {
        guard let future = session.receive(body) else {
            return
        }

        let requestFuture = future.hop(
            to: context.eventLoop
        )

        streamingChunkFuture = requestFuture
        pauseStreamingReads(
            context: context
        )

        requestFuture.whenComplete { result in
            guard
                self.streamingStart?
                    .registration
                    === start.registration
            else {
                return
            }

            self.streamingChunkFuture = nil

            switch result {
            case .success:
                self.drainStreamingChunks(
                    start: start,
                    context: context
                )

            case .failure(let error):
                self.streamingFailure = error
                self.streamingPendingChunks
                    .removeAll(
                        keepingCapacity: true
                    )
                start.registration.cancel(error)

                if self.streamingEndReceived {
                    self.finalizeStreamingIfReady(
                        context: context
                    )
                } else {
                    self.resumeStreamingReads(
                        context: context
                    )
                }
            }
        }
    }

    private func drainStreamingChunks(
        start: StreamingTransportStart,
        context: ChannelHandlerContext
    ) {
        guard
            !requestBodyTooLarge,
            streamingFailure == nil
        else {
            streamingPendingChunks.removeAll(
                keepingCapacity: true
            )

            if streamingEndReceived {
                finalizeStreamingIfReady(
                    context: context
                )
            } else {
                resumeStreamingReads(
                    context: context
                )
            }
            return
        }

        switch start.registration.currentState {
        case .pending:
            pauseStreamingReads(
                context: context
            )
            return

        case .bypass, .cancelled(_):
            streamingPendingChunks.removeAll(
                keepingCapacity: true
            )

        case .session(let session):
            while
                streamingChunkFuture == nil,
                !streamingPendingChunks.isEmpty
            {
                let chunk =
                    streamingPendingChunks
                    .removeFirst()

                consumeStreamingChunk(
                    chunk,
                    session: session,
                    start: start,
                    context: context
                )
            }
        }

        if streamingChunkFuture != nil {
            return
        }

        if streamingEndReceived {
            finalizeStreamingIfReady(
                context: context
            )
        } else {
            resumeStreamingReads(
                context: context
            )
        }
    }

    private func observeStreamingRegistration(
        _ registration: StreamingRegistration,
        context: ChannelHandlerContext
    ) {
        guard case .pending =
            registration.currentState
        else {
            return
        }

        pauseStreamingReads(
            context: context
        )

        registration.readyFuture.whenComplete { _ in
            guard
                self.streamingStart?
                    .registration
                    === registration
            else {
                return
            }

            guard let start =
                self.streamingStart
            else {
                return
            }

            self.drainStreamingChunks(
                start: start,
                context: context
            )
        }
    }

    private func finalizeStreamingIfReady(
        context: ChannelHandlerContext
    ) {
        guard
            streamingEndReceived,
            let head = requestHead,
            let start = streamingStart
        else {
            return
        }

        let isHead = head.method == .HEAD
        let version = head.version
        let keepAlive = head.isKeepAlive

        if requestBodyTooLarge {
            start.registration.cancel(
                BodyStreamError.payloadTooLarge
            )
            write(
                .payloadTooLarge(),
                isHeadRequest: isHead,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            completeStreamingRequest(
                context: context
            )
            return
        }

        if let streamingFailure {
            start.registration.cancel(
                streamingFailure
            )
            write(
                .internalServerError(),
                isHeadRequest: isHead,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            completeStreamingRequest(
                context: context
            )
            return
        }

        guard
            streamingChunkFuture == nil,
            streamingPendingChunks.isEmpty
        else {
            return
        }

        switch start.registration.currentState {
        case .pending:
            pauseStreamingReads(
                context: context
            )
            return

        case .cancelled(let error):
            start.registration.cancel(error)
            write(
                .internalServerError(),
                isHeadRequest: isHead,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .bypass:
            write(
                start.result,
                isHeadRequest: isHead,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .session(let session):
            session.finish()
            write(
                start.result,
                isHeadRequest: isHead,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
        }

        completeStreamingRequest(
            context: context
        )
    }

    private func completeStreamingRequest(
        context: ChannelHandlerContext
    ) {
        resetStreamingState()
        resumeStreamingReads(
            context: context
        )
    }

    private func resetStreamingState() {
        streamingStart = nil
        streamingPendingChunks.removeAll(
            keepingCapacity: true
        )
        streamingChunkFuture = nil
        streamingEndReceived = false
        streamingFailure = nil
        requestHead = nil
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
    }

    private func pauseStreamingReads(
        context: ChannelHandlerContext
    ) {
        guard !streamingReadsPaused else {
            return
        }

        streamingReadsPaused = true
        context.channel.setOption(
            ChannelOptions.autoRead,
            value: false
        ).whenFailure { _ in
            context.close(promise: nil)
        }
    }

    private func resumeStreamingReads(
        context: ChannelHandlerContext
    ) {
        guard streamingReadsPaused else {
            return
        }

        streamingReadsPaused = false
        context.channel.setOption(
            ChannelOptions.autoRead,
            value: true
        ).whenFailure { _ in
            context.close(promise: nil)
        }
    }

    @inline(__always)
    private func declaredBodyExceedsLimit(
        _ head: HTTPRequestHead,
        maxBodyBytes: Int
    ) -> Bool {
        guard
            let value = head.headers.first(
                name: "content-length"
            ),
            let contentLength = Int(value)
        else {
            return false
        }

        return contentLength > maxBodyBytes
    }

    private func resetRequestState() {
        requestHead = nil
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
    }

    @inline(__always)
    private func writePrepared(
        _ storage: PreparedResponseStorage,
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
                storage.response,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            return
        }

        context.write(
            wrapOutboundOut(
                .head(storage.http11Head)
            ),
            promise: nil
        )

        if
            !isHeadRequest,
            let body = storage.bodyBuffer,
            body.readableBytes > 0
        {
            context.write(
                wrapOutboundOut(
                    .body(.byteBuffer(body))
                ),
                promise: nil
            )
        }

        context.writeAndFlush(
            wrapOutboundOut(.end(nil)),
            promise: nil
        )
    }

    @inline(__always)
    private func write(
        _ result: ResponderResult,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        switch result {
        case .immediate(let response):
            write(
                response,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .prepared(let storage):
            writePrepared(
                storage,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .streaming(let session):
            write(
                session.responseFuture,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .future(let future):
            write(
                future,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
        }
    }

    private func write(
        _ future: EventLoopFuture<Response>,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        future.whenComplete { result in
            switch result {
            case .success(let response):
                self.write(
                    response,
                    isHeadRequest: isHeadRequest,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )

            case .failure:
                self.write(
                    .internalServerError(),
                    isHeadRequest: isHeadRequest,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )
            }
        }
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
            var valueBuffer =
                context.channel.allocator.buffer(
                    capacity: value.utf8.count
                )
            valueBuffer.writeString(value)
            buffer = valueBuffer

        case .bytes(let bytes):
            var valueBuffer =
                context.channel.allocator.buffer(
                    capacity: bytes.count
                )
            valueBuffer.writeBytes(bytes)
            buffer = valueBuffer

        case .buffer(let value):
            buffer = value
        }

        if headers.first(
            name: "content-length"
        ) == nil {
            headers.add(
                name: "content-length",
                value: String(
                    buffer?.readableBytes ?? 0
                )
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
                wrapOutboundOut(
                    .body(.byteBuffer(buffer))
                ),
                promise: nil
            )
        }

        context
            .writeAndFlush(
                wrapOutboundOut(.end(nil))
            )
            .whenComplete { _ in
                if !keepAlive {
                    context.close(
                        promise: nil
                    )
                }
            }
    }
}
