import NIOCore
import NIOHTTP1

final class HTTPServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let application: Application
    private let maxRequestBodyBytes: Int
    private let hasMiddleware: Bool
    private let hasStreamingRoutes: Bool
    private let canUseMinimalPreparedCacheFastPath: Bool
    private let emptyBody = ByteBufferAllocator().buffer(
        capacity: 0
    )
    private let http11OKHeadTemplate =
        HTTPResponseHead(
            version: .http1_1,
            status: .ok
        )

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var receivedBodyBytes = 0
    private var requestBodyTooLarge = false
    private var preResolvedMatch: RouterMatch?

    private var cachedRouteMethod: NIOHTTP1.HTTPMethod?
    private var cachedRouteURI: String?
    private var cachedRouteMatch: RouterMatch?
    private var cachedPreparedStorage:
        PreparedResponseStorage?

    private var streamingStart: StreamingTransportStart?
    private var streamingPendingChunks =
        CircularBuffer<ByteBuffer>(
            initialCapacity: 4
        )
    private var streamingChunkFuture:
        EventLoopFuture<Void>?
    private var streamingEndReceived = false
    private var streamingReadsPaused = false
    private var streamingFailure: Error?
    private var rejectingRequestEarly = false

    init(
        application: Application,
        maxRequestBodyBytes: Int? = nil
    ) {
        self.application = application
        self.maxRequestBodyBytes =
            maxRequestBodyBytes
            ?? application.configuration.maxRequestBodyBytes
        let hasMiddleware =
            application.hasMiddleware
        let hasStreamingRoutes =
            application.hasStreamingRoutes

        self.hasMiddleware = hasMiddleware
        self.hasStreamingRoutes = hasStreamingRoutes
        self.canUseMinimalPreparedCacheFastPath =
            !hasMiddleware
            && !hasStreamingRoutes
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
        if
            canUseMinimalPreparedCacheFastPath,
            let cachedPreparedStorage,
            cachedRouteMethod == head.method,
            cachedRouteURI == head.uri,
            requestHasMinimalHTTP11Headers(head)
        {
            writePrepared(
                cachedPreparedStorage,
                isHeadRequest:
                    head.method == .HEAD,
                version: .http1_1,
                keepAlive: true,
                context: context
            )
            return
        }

        let hasStreamingRouteForRequest =
            hasStreamingRoutes
            && application.hasStreamingRoute(
                for: head.method
            )

        var transportMatch: RouterMatch?

        let hasMinimalHTTP11Headers =
            requestHasMinimalHTTP11Headers(head)

        let canDispatchBodylessOnHead =
            hasMinimalHTTP11Headers
            || (
                head.headers.first(name: "expect") == nil
                && requestBodyIsDefinitelyEmpty(head)
            )

        if
            !hasMiddleware,
            !hasStreamingRouteForRequest,
            canDispatchBodylessOnHead
        {
            if
                cachedRouteMethod == head.method,
                cachedRouteURI == head.uri,
                let cachedPreparedStorage
            {
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)

                writePrepared(
                    cachedPreparedStorage,
                    isHeadRequest:
                        head.method == .HEAD,
                    version: head.version,
                    keepAlive: keepAlive,
                    context: context
                )
                return
            }

            let match = lookupTransportCached(head)

            switch match {
            case .prepared(let storage):
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)

                writePrepared(
                    storage,
                    isHeadRequest:
                        head.method == .HEAD,
                    version: head.version,
                    keepAlive: keepAlive,
                    context: context
                )
                return

            case .conditionalPrepared(
                let tag,
                let response,
                let notModified
            ):
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)
                let storage =
                    IfNoneMatchMatcher.matches(
                        headers: head.headers,
                        tag: tag
                    )
                    ? notModified
                    : response

                writePrepared(
                    storage,
                    isHeadRequest:
                        head.method == .HEAD,
                    version: head.version,
                    keepAlive: keepAlive,
                    context: context
                )
                return

            case .synchronous(
                let handler,
                let parameterNames,
                let parameterRanges
            ):
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)
                let request = Request(
                    head: head,
                    body: emptyBody,
                    routeParameterNames:
                        parameterNames,
                    routeParameterRanges:
                        parameterRanges
                )

                write(
                    handler(request),
                    isHeadRequest:
                        head.method == .HEAD,
                    version: head.version,
                    keepAlive: keepAlive,
                    context: context
                )
                return

            case .notFound:
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)

                writePrepared(
                    PreparedResponse
                        .defaultNotFoundStorage,
                    isHeadRequest:
                        head.method == .HEAD,
                    version: head.version,
                    keepAlive: keepAlive,
                    context: context
                )
                return

            case .asynchronous,
                 .concurrent:
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)
                let result =
                    application.respondTransport(
                        match: match,
                        head: head,
                        body: emptyBody,
                        on: context.eventLoop,
                        channel: context.channel
                    )

                write(
                    result,
                    isHeadRequest:
                        head.method == .HEAD,
                    version: head.version,
                    keepAlive: keepAlive,
                    context: context
                )
                return

            case .streaming:
                transportMatch = match
            }
        }

        requestHead = head
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
        preResolvedMatch = nil
        rejectingRequestEarly = false

        if hasStreamingRouteForRequest {
            streamingStart = nil
            streamingFailure = nil
            streamingEndReceived = false
            streamingPendingChunks.removeAll(
                keepingCapacity: true
            )
            streamingChunkFuture = nil
        }

        if hasStreamingRouteForRequest {
            let match = lookupTransportCached(
                head
            )
            transportMatch = match

            if let start = application
                .beginStreamingTransport(
                    head: head,
                    emptyBody: emptyBody,
                    match: match,
                    on: context.eventLoop,
                    channel: context.channel
                )
            {
                streamingStart = start
                requestBodyTooLarge =
                    start.declaredBodyTooLarge

                if requestBodyTooLarge {
                    start.registration.cancel(
                        BodyStreamError.payloadTooLarge
                    )

                    rejectingRequestEarly = true
                    write(
                        start.result,
                        isHeadRequest:
                            head.method == .HEAD,
                        version: head.version,
                        keepAlive: false,
                        context: context
                    )
                    return
                }

                if handleExpectation(
                    head,
                    context: context
                ) {
                    return
                }

                observeStreamingRegistration(
                    start.registration,
                    context: context
                )
                return
            }

            if !hasMiddleware {
                preResolvedMatch = match
            }
        }

        if
            !hasMiddleware,
            preResolvedMatch == nil
        {
            preResolvedMatch =
                transportMatch
                ?? lookupTransportCached(head)
        }

        requestBodyTooLarge =
            declaredBodyExceedsLimit(
                head,
                maxBodyBytes:
                    maxRequestBodyBytes
            )

        if handleExpectation(
            head,
            context: context
        ) {
            return
        }

        guard
            !requestBodyTooLarge,
            requestBodyIsDefinitelyEmpty(head),
            let preResolvedMatch
        else {
            return
        }

        let result = application.respondTransport(
            match: preResolvedMatch,
            head: head,
            body: emptyBody,
            on: context.eventLoop,
            channel: context.channel
        )

        write(
            result,
            isHeadRequest: head.method == .HEAD,
            version: head.version,
            keepAlive: requestIsKeepAlive(head),
            context: context
        )
        resetRequestState()
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
    private func requestBodyIsDefinitelyEmpty(
        _ head: HTTPRequestHead
    ) -> Bool {
        guard head.headers.first(
            name: "transfer-encoding"
        ) == nil else {
            return false
        }

        guard head.headers.first(
            name: "content-length"
        ) != nil else {
            return true
        }

        return HTTPContentLength.hasSingleExactValue(
            head.headers,
            value: "0"
        )
    }

    private func receiveBody(
        _ body: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        guard !rejectingRequestEarly else {
            return
        }

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

        if rejectingRequestEarly {
            if streamingStart != nil {
                resetStreamingState()
            } else {
                resetRequestState()
            }

            rejectingRequestEarly = false
            return
        }

        if streamingStart != nil {
            streamingEndReceived = true
            finalizeStreamingIfReady(
                context: context
            )
            return
        }

        let keepAlive = requestIsKeepAlive(head)
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

        let result: ResponderResult

        if let preResolvedMatch {
            result = application.respondTransport(
                match: preResolvedMatch,
                head: head,
                body: requestBody ?? emptyBody,
                on: context.eventLoop,
                channel: context.channel
            )
        } else {
            result = application.respondTransport(
                head: head,
                body: requestBody ?? emptyBody,
                on: context.eventLoop,
                channel: context.channel
            )
        }

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
        let future: EventLoopFuture<Void>?

        do {
            future = try session.receive(body)
        } catch {
            failStreamingChunk(
                error,
                start: start,
                context: context
            )
            return
        }

        guard let future else {
            return
        }

        let requestFuture = future.hop(
            to: context.eventLoop
        )

        streamingChunkFuture = requestFuture
        pauseStreamingReads(
            context: context
        )

        requestFuture
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
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
                self.failStreamingChunk(
                    error,
                    start: start,
                    context: context
                )
            }
        }
    }

    private func failStreamingChunk(
        _ error: Error,
        start: StreamingTransportStart,
        context: ChannelHandlerContext
    ) {
        streamingFailure = error
        streamingPendingChunks.removeAll(
            keepingCapacity: true
        )
        start.registration.cancel(error)

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
                guard let chunk =
                    streamingPendingChunks.popFirst()
                else {
                    break
                }

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

        registration.readyFuture
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { _ in
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
        let keepAlive = requestIsKeepAlive(head)

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
            writeFailure(
                streamingFailure,
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
            writeFailure(
                error,
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
        preResolvedMatch = nil
        rejectingRequestEarly = false
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
        )
        .assumeIsolatedUnsafeUnchecked()
        .whenFailure { _ in
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
        )
        .assumeIsolatedUnsafeUnchecked()
        .whenFailure { _ in
            context.close(promise: nil)
        }
    }

    private func handleExpectation(
        _ head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) -> Bool {
        guard let expectation = head.headers.first(
            name: "expect"
        ) else {
            return false
        }

        guard
            head.version == .http1_1,
            expectation.lowercased()
                == "100-continue"
        else {
            streamingStart?.registration.cancel(
                BodyStreamError.connectionClosed
            )
            rejectRequestEarly(
                .text(
                    "Expectation Failed",
                    status: .expectationFailed
                ),
                head: head,
                context: context
            )
            return true
        }

        if requestBodyTooLarge {
            streamingStart?.registration.cancel(
                BodyStreamError.payloadTooLarge
            )
            rejectRequestEarly(
                .payloadTooLarge(),
                head: head,
                context: context
            )
            return true
        }

        let continueHead = HTTPResponseHead(
            version: .http1_1,
            status: .continue
        )

        context.writeAndFlush(
            wrapOutboundOut(
                .head(continueHead)
            ),
            promise: nil
        )

        return false
    }

    private func rejectRequestEarly(
        _ response: Response,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        rejectingRequestEarly = true

        write(
            response,
            isHeadRequest: head.method == .HEAD,
            version: head.version,
            keepAlive: false,
            context: context
        )
    }

    @inline(__always)
    private func declaredBodyExceedsLimit(
        _ head: HTTPRequestHead,
        maxBodyBytes: Int
    ) -> Bool {
        HTTPContentLength.declaredExceedsLimit(
            head.headers,
            limit: maxBodyBytes
        )
    }

    private func resetRequestState() {
        requestHead = nil
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
        preResolvedMatch = nil
        rejectingRequestEarly = false
    }

    @inline(__always)
    private func lookupTransportCached(
        _ head: HTTPRequestHead
    ) -> RouterMatch {
        if
            cachedRouteMethod == head.method,
            cachedRouteURI == head.uri,
            let cachedRouteMatch
        {
            return cachedRouteMatch
        }

        let match = application.lookupTransport(
            head: head
        )

        cachedRouteMethod = head.method
        cachedRouteURI = head.uri
        cachedRouteMatch = match

        if case .prepared(let storage) = match {
            cachedPreparedStorage = storage
        } else {
            cachedPreparedStorage = nil
        }

        return match
    }

    @inline(__always)
    private func writePrepared(
        _ storage: PreparedResponseStorage,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        if
            version == .http1_1,
            keepAlive
        {
            context.write(
                wrapOutboundOut(
                    .head(storage.http11Head)
                ),
                promise: nil
            )

            if
                !isHeadRequest,
                let body = storage.bodyBuffer
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
            return
        }

        guard storage.response.status.mayHaveResponseBody else {
            writeBodylessStatus(
                storage.response,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            return
        }

        write(
            storage.response,
            isHeadRequest: isHeadRequest,
            version: version,
            keepAlive: keepAlive,
            context: context
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
        future
            .hop(to: context.eventLoop)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                guard context.channel.isActive else {
                    return
                }

                switch result {
                case .success(let response):
                    self.write(
                        response,
                        isHeadRequest: isHeadRequest,
                        version: version,
                        keepAlive: keepAlive,
                        context: context
                    )

                case .failure(let error):
                    self.writeFailure(
                        error,
                        isHeadRequest: isHeadRequest,
                        version: version,
                        keepAlive: keepAlive,
                        context: context
                    )
                }
            }
    }

    private func writeFailure(
        _ error: Error,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        switch application.respondError(
            error,
            on: context.eventLoop,
            channel: context.channel
        ) {
        case .immediate(let response):
            write(
                response,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .future(let future):
            future
                .assumeIsolatedUnsafeUnchecked()
                .whenComplete { result in
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
    }

    private func write(
        _ response: Response,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        guard response.status.mayHaveResponseBody else {
            writeBodylessStatus(
                response,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            return
        }

        if case .stream(let stream) = response.body {
            writeStream(
                stream,
                response: response,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            return
        }

        var headers = response.headers
        let body: IOData?
        let bodyLength: Int

        switch response.body {
        case .empty:
            body = nil
            bodyLength = 0

        case .text(let value):
            var valueBuffer =
                context.channel.allocator.buffer(
                    capacity: value.utf8.count
                )
            valueBuffer.writeString(value)
            body = .byteBuffer(valueBuffer)
            bodyLength = valueBuffer.readableBytes

        case .bytes(let bytes):
            var valueBuffer =
                context.channel.allocator.buffer(
                    capacity: bytes.count
                )
            valueBuffer.writeBytes(bytes)
            body = .byteBuffer(valueBuffer)
            bodyLength = valueBuffer.readableBytes

        case .buffer(let value):
            body = .byteBuffer(value)
            bodyLength = value.readableBytes

        case .fileRegion(let value):
            body = .fileRegion(value)
            bodyLength = value.readableBytes

        case .stream:
            preconditionFailure(
                "Stream bodies must use the streaming response writer"
            )
        }

        if !response.contentLengthIsNormalized {
            let contentLengthValue =
                String(bodyLength)

            if !HTTPContentLength.hasSingleExactValue(
                headers,
                value: contentLengthValue
            ) {
                headers.replaceOrAdd(
                    name: "content-length",
                    value: contentLengthValue
                )
            }
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

        let head: HTTPResponseHead

        if
            version == .http1_1,
            response.status == .ok
        {
            var cachedHead =
                http11OKHeadTemplate
            cachedHead.headers = headers
            head = cachedHead
        } else {
            head = HTTPResponseHead(
                version: version,
                status: response.status,
                headers: headers
            )
        }

        context.write(
            wrapOutboundOut(.head(head)),
            promise: nil
        )

        if
            !isHeadRequest,
            let body,
            bodyLength > 0
        {
            context.write(
                wrapOutboundOut(
                    .body(body)
                ),
                promise: nil
            )
        }

        finishResponse(
            keepAlive: keepAlive,
            context: context
        )
    }


    private func writeBodylessStatus(
        _ response: Response,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        var headers = response.headers

        headers.remove(
            name: "transfer-encoding"
        )

        if response.status != .notModified {
            headers.remove(
                name: "content-length"
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

        finishResponse(
            keepAlive: keepAlive,
            context: context
        )
    }

    private func writeStream(
        _ stream: ResponseStream,
        response: Response,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        var headers = response.headers
        let declaredLengthResult =
            declaredStreamContentLength(
                headers: headers
            )

        let lengthTracker: ResponseStreamLengthTracker?

        switch declaredLengthResult {
        case .success(let declaredLength):
            if let declaredLength {
                lengthTracker =
                    ResponseStreamLengthTracker(
                        expected: declaredLength
                    )
            } else {
                lengthTracker = nil
            }

        case .failure(let error):
            stream.errorHandler?(error)
            writeFailure(
                error,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            return
        }

        let hasKnownLength =
            lengthTracker != nil
        let streamKeepAlive =
            keepAlive
            && (
                version != .http1_0
                || hasKnownLength
            )

        if !streamKeepAlive {
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

        if isHeadRequest {
            finishStreamResponse(
                keepAlive: streamKeepAlive,
                context: context
            )
            return
        }

        let writer = ResponseStreamWriter(
            context: context,
            lengthTracker: lengthTracker
        )
        let future = stream.producer(writer).hop(
            to: context.eventLoop
        )

        future
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                guard context.channel.isActive else {
                return
            }

            switch result {
            case .success:
                if let error =
                    lengthTracker?.completionError()
                {
                    stream.errorHandler?(error)
                    context.flush()
                    context.close(promise: nil)
                    return
                }

                self.finishStreamResponse(
                    keepAlive: streamKeepAlive,
                    context: context
                )

            case .failure(let error):
                stream.errorHandler?(error)
                context.flush()
                context.close(promise: nil)
            }
        }
    }

    @inline(__always)
    private func declaredStreamContentLength(
        headers: HTTPHeaders
    ) -> Result<Int?, ResponseStreamError> {
        var firstRawValue: String?
        var parsedLength: Int?

        for (name, value) in headers {
            guard Self.isContentLengthHeader(name) else {
                continue
            }

            if let firstRawValue {
                return .failure(
                    .ambiguousContentLength([
                        firstRawValue,
                        value
                    ])
                )
            }

            if value.utf8.contains(44) {
                return .failure(
                    .ambiguousContentLength([
                        value
                    ])
                )
            }

            guard let contentLength =
                Self.parseContentLength(value)
            else {
                return .failure(
                    .invalidContentLength(value)
                )
            }

            firstRawValue = value
            parsedLength = contentLength
        }

        return .success(parsedLength)
    }

    @inline(__always)
    private static func isContentLengthHeader(
        _ name: String
    ) -> Bool {
        let bytes = name.utf8
        let expected = "content-length".utf8

        guard bytes.count == expected.count else {
            return false
        }

        var left = bytes.startIndex
        var right = expected.startIndex

        while left != bytes.endIndex {
            let byte = bytes[left]
            let folded =
                byte >= 65 && byte <= 90
                ? byte + 32
                : byte

            guard folded == expected[right] else {
                return false
            }

            bytes.formIndex(after: &left)
            expected.formIndex(after: &right)
        }

        return true
    }

    @inline(__always)
    private static func parseContentLength(
        _ value: String
    ) -> Int? {
        let bytes = value.utf8

        guard !bytes.isEmpty else {
            return nil
        }

        var result = 0

        for byte in bytes {
            guard byte >= 48 && byte <= 57 else {
                return nil
            }

            let digit = Int(byte - 48)

            guard
                result
                <= (Int.max - digit) / 10
            else {
                return nil
            }

            result =
                result * 10
                + digit
        }

        return result
    }

    @inline(__always)
    private func finishResponse(
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
                context.close(
                    promise: nil
                )
            }
    }

    private func finishStreamResponse(
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        finishResponse(
            keepAlive: keepAlive,
            context: context
        )
    }

}
