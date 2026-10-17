import NIOCore
import NIOHTTP1

/// Event-loop-bound HTTP/1.1 connection handler.
///
/// Owns request decoding, keep-alive state, per-connection route
/// caching, body aggregation mechanics, request streaming mechanics
/// with backpressure, 100-continue handling, and response emission.
/// Runs entirely on the channel event loop; the only permitted
/// hop-off is an explicit async dispatcher future, which hops back
/// before writing.
///
/// Dispatch behavior is a verbatim port of the pre-refactor
/// `HTTPServerHandler`: minimal-header fast path, bodyless dispatch
/// on head, slow path with aggregation, and the streaming pump. All
/// framework semantics (routing, middleware, error mapping) arrive
/// through the dispatcher, which is invoked on this same loop.
public final class RuntimeConnectionHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private let dispatcher: RuntimeDispatcher
    private let maxRequestBodyBytes: Int
    private let hasMiddleware: Bool
    private let hasStreamingRoutes: Bool
    private let canUseMinimalRouteCacheFastPath: Bool
    private static let sharedEmptyBody =
        ByteBufferAllocator().buffer(capacity: 0)

    private var emptyBody: ByteBuffer {
        Self.sharedEmptyBody
    }

    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var receivedBodyBytes = 0
    private var requestBodyTooLarge = false
    private var preResolvedAction: RuntimeRouteAction?

    private var cachedRouteMethod: NIOHTTP1.HTTPMethod?
    private var cachedRouteURI: String?
    private var cachedRouteAction: RuntimeRouteAction?
    private var cachedRemoteAddress: SocketAddress?
    private var cachedRemoteAddressLoaded = false

    private var streamingStart: RuntimeStreamingStart?
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

    public init(
        dispatcher: RuntimeDispatcher,
        configuration: RuntimeServerConfiguration
    ) {
        self.dispatcher = dispatcher
        self.maxRequestBodyBytes =
            configuration.maxRequestBodyBytes
        let hasMiddleware =
            dispatcher.hasMiddleware
        let hasStreamingRoutes =
            dispatcher.hasStreamingRoutes

        self.hasMiddleware = hasMiddleware
        self.hasStreamingRoutes = hasStreamingRoutes
        self.canUseMinimalRouteCacheFastPath =
            !hasMiddleware
            && !hasStreamingRoutes
    }

    public func channelRead(
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

    public func channelInactive(
        context: ChannelHandlerContext
    ) {
        streamingStart?.registration.cancel(
            RuntimeRequestStreamError.connectionClosed
        )
        resetStreamingState()
        streamingReadsPaused = false
        context.fireChannelInactive()
    }

    public func errorCaught(
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
            canUseMinimalRouteCacheFastPath,
            cachedRouteMethod == head.method,
            cachedRouteURI == head.uri,
            requestHasMinimalHTTP11Headers(head)
        {
            if let cachedRouteAction {
                switch cachedRouteAction {
                case .prepared(let storage):
                    writePrepared(
                        storage,
                        isHeadRequest:
                            head.method == .HEAD,
                        version: .http1_1,
                        keepAlive: true,
                        context: context
                    )
                    return

                case .sync(let action):
                    writeMinimalHTTP11(
                        action.run(
                            RuntimeRequest(
                                head: head,
                                body: emptyBody
                            )
                        ),
                        isHeadRequest:
                            head.method == .HEAD,
                        context: context
                    )
                    return

                case .async(let action):
                    write(
                        action.run(
                            RuntimeRequest(
                                head: head,
                                body: emptyBody,
                                remoteAddress:
                                    cachedRemoteAddress(
                                        for: context
                                    )
                            ),
                            context.eventLoop
                        ),
                        isHeadRequest:
                            head.method == .HEAD,
                        version: .http1_1,
                        keepAlive: true,
                        context: context
                    )
                    return

                case .streaming:
                    break
                }
            }
        }

        let hasStreamingRouteForRequest =
            hasStreamingRoutes
            && dispatcher.hasStreamingRoute(
                head.method
            )

        var transportAction: RuntimeRouteAction?

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
            let routeMatchesCache =
                cachedRouteMethod == head.method
                && cachedRouteURI == head.uri

            let action: RuntimeRouteAction

            if
                routeMatchesCache,
                let cachedRouteAction
            {
                action = cachedRouteAction
            } else {
                action = lookupTransportCached(head)
            }

            switch action {
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

            case .sync(let syncAction):
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)
                let response = syncAction.run(
                    RuntimeRequest(
                        head: head,
                        body: emptyBody
                    )
                )

                if hasMinimalHTTP11Headers {
                    writeMinimalHTTP11(
                        response,
                        isHeadRequest:
                            head.method == .HEAD,
                        context: context
                    )
                } else {
                    write(
                        response,
                        isHeadRequest:
                            head.method == .HEAD,
                        version: head.version,
                        keepAlive: keepAlive,
                        context: context
                    )
                }
                return

            case .async(let asyncAction):
                let keepAlive =
                    hasMinimalHTTP11Headers
                    || requestIsKeepAlive(head)

                write(
                    asyncAction.run(
                        RuntimeRequest(
                            head: head,
                            body: emptyBody,
                            remoteAddress:
                                cachedRemoteAddress(
                                    for: context
                                )
                        ),
                        context.eventLoop
                    ),
                    isHeadRequest:
                        head.method == .HEAD,
                    version: head.version,
                    keepAlive: keepAlive,
                    context: context
                )
                return

            case .streaming:
                transportAction = action
            }
        }

        requestHead = head
        requestBody = nil
        receivedBodyBytes = 0
        requestBodyTooLarge = false
        preResolvedAction = nil
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
            let action = lookupTransportCached(
                head
            )
            transportAction = action

            if
                case .streaming(let streamingAction) =
                    action,
                let start = streamingAction.begin(
                    RuntimeRequest(
                        head: head,
                        body: emptyBody,
                        remoteAddress:
                            context.channel.remoteAddress
                    ),
                    context.eventLoop
                )
            {
                streamingStart = start
                requestBodyTooLarge =
                    start.declaredBodyTooLarge

                if requestBodyTooLarge {
                    start.registration.cancel(
                        RuntimeRequestStreamError
                            .payloadTooLarge
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
                preResolvedAction = action
            }
        }

        if
            !hasMiddleware,
            preResolvedAction == nil
        {
            preResolvedAction =
                transportAction
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
            let preResolvedAction
        else {
            return
        }

        let result = runPreResolved(
            preResolvedAction,
            head: head,
            body: emptyBody,
            context: context
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
    private func runPreResolved(
        _ action: RuntimeRouteAction,
        head: HTTPRequestHead,
        body: ByteBuffer,
        context: ChannelHandlerContext
    ) -> RuntimeDispatchResult {
        switch action {
        case .prepared(let storage):
            return .prepared(storage)

        case .sync(let syncAction):
            return .response(
                syncAction.run(
                    RuntimeRequest(
                        head: head,
                        body: body
                    )
                )
            )

        case .async(let asyncAction):
            return .future(
                asyncAction.run(
                    RuntimeRequest(
                        head: head,
                        body: body,
                        remoteAddress:
                            context.channel.remoteAddress
                    ),
                    context.eventLoop
                )
            )

        case .streaming(let streamingAction):
            return streamingAction.runAggregated(
                RuntimeRequest(
                    head: head,
                    body: body,
                    remoteAddress:
                        context.channel.remoteAddress
                ),
                context.eventLoop
            )
        }
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
                    RuntimeRequestStreamError
                        .payloadTooLarge
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
                .prepared(
                    dispatcher.payloadTooLarge
                ),
                isHeadRequest: isHead,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
            resetRequestState()
            return
        }

        let result: RuntimeDispatchResult

        if let preResolvedAction {
            result = runPreResolved(
                preResolvedAction,
                head: head,
                body: requestBody ?? emptyBody,
                context: context
            )
        } else {
            result = dispatcher.dispatchPipeline(
                RuntimeRequest(
                    head: head,
                    body: requestBody ?? emptyBody,
                    remoteAddress:
                        context.channel.remoteAddress
                ),
                context.eventLoop
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
        start: RuntimeStreamingStart,
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
        session: RuntimeStreamSession,
        start: RuntimeStreamingStart,
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
        start: RuntimeStreamingStart,
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
        start: RuntimeStreamingStart,
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
        _ registration: RuntimeStreamRegistration,
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
                RuntimeRequestStreamError.payloadTooLarge
            )
            write(
                .prepared(
                    dispatcher.payloadTooLarge
                ),
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
        preResolvedAction = nil
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
                RuntimeRequestStreamError
                    .connectionClosed
            )
            rejectRequestEarly(
                dispatcher.expectationFailed,
                head: head,
                context: context
            )
            return true
        }

        if requestBodyTooLarge {
            streamingStart?.registration.cancel(
                RuntimeRequestStreamError.payloadTooLarge
            )
            rejectRequestEarly(
                dispatcher.payloadTooLarge,
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
        _ storage: RuntimePreparedResponse,
        head: HTTPRequestHead,
        context: ChannelHandlerContext
    ) {
        rejectingRequestEarly = true

        writePrepared(
            storage,
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
        preResolvedAction = nil
        rejectingRequestEarly = false
    }

    @inline(__always)
    private func cachedRemoteAddress(
        for context: ChannelHandlerContext
    ) -> SocketAddress? {
        if cachedRemoteAddressLoaded {
            return cachedRemoteAddress
        }

        let address =
            context.channel.remoteAddress
        cachedRemoteAddress = address
        cachedRemoteAddressLoaded = true
        return address
    }

    @inline(__always)
    private func lookupTransportCached(
        _ head: HTTPRequestHead
    ) -> RuntimeRouteAction {
        if
            cachedRouteMethod == head.method,
            cachedRouteURI == head.uri,
            let cachedRouteAction
        {
            return cachedRouteAction
        }

        let action = dispatcher.lookup(head)

        cachedRouteMethod = head.method
        cachedRouteURI = head.uri
        cachedRouteAction = action

        return action
    }

    @inline(__always)
    private func writePrepared(
        _ storage: RuntimePreparedResponse,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        RuntimeResponseWriter(context: context)
            .writePrepared(
                storage,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                onFailure: { error in
                    self.writeFailure(
                        error,
                        isHeadRequest: isHeadRequest,
                        version: version,
                        keepAlive: keepAlive,
                        context: context
                    )
                }
            )
    }

    @inline(__always)
    private func write(
        _ result: RuntimeDispatchResult,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        switch result {
        case .response(let response):
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
        _ future: EventLoopFuture<RuntimeResponse>,
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
        switch dispatcher.mapError(
            error,
            context.eventLoop,
            context.channel.remoteAddress
        ) {
        case .response(let response):
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
                    self.writePrepared(
                        self.dispatcher
                            .internalServerError,
                        isHeadRequest: isHeadRequest,
                        version: version,
                        keepAlive: keepAlive,
                        context: context
                    )
                }
            }
        }
    }

    @inline(__always)
    private func writeMinimalHTTP11(
        _ response: RuntimeResponse,
        isHeadRequest: Bool,
        context: ChannelHandlerContext
    ) {
        RuntimeResponseWriter(context: context)
            .writeMinimal(
                response,
                isHeadRequest: isHeadRequest,
                onFailure: { error in
                    self.writeFailure(
                        error,
                        isHeadRequest: isHeadRequest,
                        version: .http1_1,
                        keepAlive: true,
                        context: context
                    )
                }
            )
    }

    private func write(
        _ response: RuntimeResponse,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        RuntimeResponseWriter(context: context).write(
            response,
            onFailure: { error in
                self.writeFailure(
                    error,
                    isHeadRequest: isHeadRequest,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )
            },
            isHeadRequest: isHeadRequest,
            version: version,
            keepAlive: keepAlive
        )
    }
}
