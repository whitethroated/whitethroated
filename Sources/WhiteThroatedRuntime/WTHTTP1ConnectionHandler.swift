import NIOCore
import NIOHTTP1

import WhiteThroatedHTTP1

/// Experimental Tier 1 HTTP/1 connection handler.
///
/// Speaks raw `ByteBuffer` in both directions, replacing the stock
/// `HTTPRequestDecoder` + `HTTPServerPipelineHandler` +
/// `HTTPServerProtocolErrorHandler` + `HTTPResponseEncoder` chain with
/// `WTHTTP1Parser` + `WTHTTP1ResponseWriter` while staying on
/// `NIOCore`/`NIOPosix` for event loops, sockets, and buffers.
///
/// Dispatch semantics mirror `RuntimeConnectionHandler` point for
/// point (minimal-header fast path, bodyless dispatch on head,
/// per-connection route cache, body aggregation with limits,
/// 100-continue, early rejects, async ordering for pipelining); the
/// framework-facing `RuntimeDispatcher` contract is unchanged. The
/// dispatcher still speaks NIO request/response types, so one
/// boundary conversion per request is the known Tier 1 tax this
/// experiment measures around.
///
/// Documented Tier 1 divergences (all fail safe, never permissive):
/// - Request-streaming routes are answered 500
///   (`internalServerError`, keep-alive preserved) without invoking
///   the consumer; stock would stream. A 413 still wins when a body
///   limit is exceeded first.
/// - `fileRegion`/`stream` response bodies are answered 500 without
///   invoking the producer; stock would serve them.
/// - Chunked trailer VALUES are validated then discarded; framing is
///   equivalent with stock.
/// - A response the writer refuses (invalid bytes, mirroring NIO's
///   outbound validator) closes the connection silently.
public final class WTHTTP1ConnectionHandler:
    ChannelDuplexHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private struct ActiveRequest {
        var head: HTTPRequestHead
        var method: WTHTTP1Method
        var version: WTHTTP1Version
        var keepAlive: Bool
        var isHeadRequest: Bool
        var sequence: Int
        var body: ByteBuffer
        var receivedBodyBytes: Int
        var remainingBodyBytes: Int
        var chunkState: WTHTTP1ChunkState
        var isChunked: Bool
        var discardingBody: Bool
        var preResolvedAction: RuntimeRouteAction?
        var streamingUnsupported: Bool
    }

    private struct HeldResponse {
        var bytes: ByteBuffer
        var closeAfter: Bool
    }

    private static let sharedEmptyBody =
        ByteBufferAllocator().buffer(capacity: 0)

    private static let badRequestBytes: [UInt8] = Array(
        "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
            .utf8
    )

    private let dispatcher: RuntimeDispatcher
    private let maxRequestBodyBytes: Int
    private let hasMiddleware: Bool
    private let hasStreamingRoutes: Bool
    private let canUseMinimalRouteCacheFastPath: Bool
    private let parser = WTHTTP1Parser()

    private var cumulation: ByteBuffer
    private var closed = false
    private var activeRequest: ActiveRequest?

    private var nextSequence = 0
    private var emitSequence = 0
    private var heldResponses: [Int: HeldResponse]?

    private var cachedRouteMethod: WTHTTP1Method?
    private var cachedRouteURI: [UInt8]?
    private var cachedRouteAction: RuntimeRouteAction?
    private var cachedSealedResponse: WTHTTP1SealedResponse?
    private var cachedSealedOwner: ObjectIdentifier?
    private var cachedRemoteAddress: SocketAddress?
    private var cachedRemoteAddressLoaded = false

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
        self.cumulation =
            ByteBufferAllocator().buffer(
                capacity: 1024
            )
    }

    public func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        guard !closed else {
            return
        }

        var input = unwrapInboundIn(data)
        cumulation.writeBuffer(&input)
        drain(context: context)
    }

    public func channelInactive(
        context: ChannelHandlerContext
    ) {
        context.fireChannelInactive()
    }

    public func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        closed = true
        context.close(promise: nil)
    }

    /// Parses and dispatches as far as the cumulated bytes allow:
    /// head, then body if any, then the next pipelined head. Stops on
    /// need-more-data or on a fatal (close the connection).
    private func drain(
        context: ChannelHandlerContext
    ) {
        while !closed {
            if activeRequest == nil {
                let head: WTHTTP1RequestHead?

                do {
                    head = try parser.parseHead(
                        from: &cumulation
                    )
                } catch {
                    writeBadRequestAndClose(
                        context: context
                    )
                    return
                }

                guard let head else {
                    compactCumulation()
                    return
                }

                beginRequest(
                    head,
                    context: context
                )
            } else if consumeBody(
                context: context
            ) {
                continue
            } else {
                compactCumulation()
                return
            }
        }
    }

    private func compactCumulation() {
        if cumulation.readableBytes == 0 {
            cumulation.clear()
            return
        }

        if cumulation.readerIndex > 8192 {
            cumulation.discardReadBytes()
        }
    }

    private func beginRequest(
        _ head: WTHTTP1RequestHead,
        context: ChannelHandlerContext
    ) {
        let method = head.method
        let uri = head.uriBytes()
        let nioHead = convertHead(
            head,
            method: method,
            uri: uri
        )
        let isHeadRequest = method == .head

        // Minimal-header fast path, mirroring stock: cache hit on
        // (method, URI) with a minimal HTTP/1.1 head dispatches
        // immediately with hardcoded version and keep-alive.
        if
            canUseMinimalRouteCacheFastPath,
            cachedRouteMethod == method,
            cachedRouteURI == uri,
            requestHasMinimalHeaders(head)
        {
            if let cachedRouteAction {
                switch cachedRouteAction {
                case .prepared(let storage):
                    writePreparedFast(
                        storage,
                        method: method,
                        isHeadRequest: isHeadRequest,
                        context: context
                    )
                    return

                case .sync(let action):
                    writeSyncMinimal(
                        action.run(
                            RuntimeRequest(
                                head: nioHead,
                                body: Self.sharedEmptyBody
                            )
                        ),
                        method: method,
                        isHeadRequest: isHeadRequest,
                        context: context
                    )
                    return

                case .async(let action):
                    writeFuture(
                        action.run(
                            RuntimeRequest(
                                head: nioHead,
                                body: Self.sharedEmptyBody,
                                remoteAddress:
                                    cachedRemoteAddress(
                                        for: context
                                    )
                            ),
                            context.eventLoop
                        ),
                        method: method,
                        isHeadRequest: isHeadRequest,
                        version: .http11,
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
                nioHead.method
            )

        let hasMinimalHeaders =
            requestHasMinimalHeaders(head)

        // Note: an empty Transfer-Encoding resolves to `.none`
        // framing here while stock `requestBodyIsDefinitelyEmpty`
        // returns false for any present TE header. Both dispatch the
        // same response; Tier 1 only skips waiting for a `.end` that
        // carries no body either way.
        let canDispatchBodylessOnHead =
            hasMinimalHeaders
            || (
                head.expectation == .none
                && head.framing == .none
            )

        if
            !hasMiddleware,
            !hasStreamingRouteForRequest,
            canDispatchBodylessOnHead
        {
            let action = lookupTransportCached(
                nioHead,
                method: method,
                uri: uri
            )

            switch action {
            case .prepared(let storage):
                writePreparedGeneral(
                    storage,
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: head.version,
                    keepAlive: hasMinimalHeaders
                        || head.keepAlive,
                    context: context
                )
                return

            case .sync(let syncAction):
                let response = syncAction.run(
                    RuntimeRequest(
                        head: nioHead,
                        body: Self.sharedEmptyBody
                    )
                )

                if hasMinimalHeaders {
                    writeSyncMinimal(
                        response,
                        method: method,
                        isHeadRequest: isHeadRequest,
                        context: context
                    )
                } else {
                    writeSyncGeneral(
                        response,
                        method: method,
                        isHeadRequest: isHeadRequest,
                        version: head.version,
                        keepAlive: head.keepAlive,
                        context: context
                    )
                }
                return

            case .async(let asyncAction):
                writeFuture(
                    asyncAction.run(
                        RuntimeRequest(
                            head: nioHead,
                            body: Self.sharedEmptyBody,
                            remoteAddress:
                                cachedRemoteAddress(
                                    for: context
                                )
                        ),
                        context.eventLoop
                    ),
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: head.version,
                    keepAlive: hasMinimalHeaders
                        || head.keepAlive,
                    context: context
                )
                return

            case .streaming:
                // Falls through to the buffered path below, where a
                // streaming route resolves to the Tier 1 500.
                break
            }
        }

        startBufferedRequest(
            head,
            nioHead: nioHead,
            method: method,
            uri: uri,
            isHeadRequest: isHeadRequest,
            hasStreamingRouteForRequest:
                hasStreamingRouteForRequest,
            context: context
        )
    }

    private func startBufferedRequest(
        _ head: WTHTTP1RequestHead,
        nioHead: HTTPRequestHead,
        method: WTHTTP1Method,
        uri: [UInt8],
        isHeadRequest: Bool,
        hasStreamingRouteForRequest: Bool,
        context: ChannelHandlerContext
    ) {
        let sequence = nextSequence
        nextSequence += 1

        var preResolvedAction: RuntimeRouteAction?
        var streamingUnsupported = false

        if hasStreamingRouteForRequest {
            let action = lookupTransportCached(
                nioHead,
                method: method,
                uri: uri
            )

            // Tier 1 never starts request streaming: the route is
            // answered 500 after its body is consumed within limits.
            // The consumer is deliberately not invoked.
            if case .streaming = action {
                streamingUnsupported = true
            } else if !hasMiddleware {
                preResolvedAction = action
            }
        }

        if
            !hasMiddleware,
            preResolvedAction == nil,
            !streamingUnsupported
        {
            let action = lookupTransportCached(
                nioHead,
                method: method,
                uri: uri
            )

            if case .streaming = action {
                streamingUnsupported = true
            } else {
                preResolvedAction = action
            }
        }

        // A single valid Content-Length (or none) is all the parser
        // admits, so this is exactly stock
        // `declaredBodyExceedsLimit`, which reads the first value.
        let declaredTooLarge: Bool
        let remainingBodyBytes: Int
        let isChunked: Bool

        switch head.framing {
        case .contentLength(let length):
            declaredTooLarge =
                length > maxRequestBodyBytes
            remainingBodyBytes = length
            isChunked = false

        case .chunked:
            declaredTooLarge = false
            remainingBodyBytes = 0
            isChunked = true

        case .none:
            declaredTooLarge = false
            remainingBodyBytes = 0
            isChunked = false
        }

        // Expectation handling mirrors stock exactly: unsupported
        // (including any non-HTTP/1.1 expectation) is 417 + close,
        // 100-continue over the limit is early 413 + close, and a
        // satisfiable 100-continue is answered before the body.
        if head.expectation == .unsupported {
            rejectRequestEarly(
                dispatcher.expectationFailed,
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: head.version,
                context: context
            )
            return
        }

        if head.expectation == .continue100 {
            if declaredTooLarge {
                rejectRequestEarly(
                    dispatcher.payloadTooLarge,
                    sequence: sequence,
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: head.version,
                    context: context
                )
                return
            }

            writeContinue(context: context)
        }

        // A `.none` framing proves the request is already complete,
        // so middleware and streaming-unsupported routes dispatch
        // immediately instead of waiting for a body `.end` that only
        // exists in decoder mechanics.
        if
            !declaredTooLarge,
            head.framing == .none
        {
            if streamingUnsupported {
                writeUnsupportedStreaming(
                    sequence: sequence,
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: head.version,
                    keepAlive: head.keepAlive,
                    context: context
                )
                return
            }

            if let preResolvedAction {
                writePreResolved(
                    preResolvedAction,
                    nioHead: nioHead,
                    body: Self.sharedEmptyBody,
                    sequence: sequence,
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: head.version,
                    keepAlive: head.keepAlive,
                    context: context
                )
                return
            }

            if hasMiddleware {
                writeDispatchResult(
                    dispatcher.dispatchPipeline(
                        RuntimeRequest(
                            head: nioHead,
                            body: Self.sharedEmptyBody,
                            remoteAddress: context.channel
                                .remoteAddress
                        ),
                        context.eventLoop
                    ),
                    sequence: sequence,
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: head.version,
                    keepAlive: head.keepAlive,
                    context: context
                )
                return
            }
        }

        // Fail safe, never stall: `.none` framing always
        // dispatches above, so reaching here with no body to wait
        // for is impossible; closing beats hanging the connection.
        if !isChunked, remainingBodyBytes == 0 {
            writeBadRequestAndClose(
                context: context
            )
            return
        }

        activeRequest = ActiveRequest(
            head: nioHead,
            method: method,
            version: head.version,
            keepAlive: head.keepAlive,
            isHeadRequest: isHeadRequest,
            sequence: sequence,
            body: context.channel.allocator.buffer(
                capacity: 0
            ),
            receivedBodyBytes: 0,
            remainingBodyBytes: remainingBodyBytes,
            chunkState: WTHTTP1ChunkState(),
            isChunked: isChunked,
            discardingBody: declaredTooLarge,
            preResolvedAction: preResolvedAction,
            streamingUnsupported: streamingUnsupported
        )
    }

    /// Returns true when the active request completed (and was
    /// dispatched), false when more bytes are needed.
    private func consumeBody(
        context: ChannelHandlerContext
    ) -> Bool {
        guard var request = activeRequest else {
            return true
        }

        if request.isChunked {
            return consumeChunkedBody(
                &request,
                context: context
            )
        }

        let take = min(
            request.remainingBodyBytes,
            cumulation.readableBytes
        )

        guard take > 0 else {
            activeRequest = request
            return false
        }

        if request.discardingBody {
            cumulation.moveReaderIndex(
                forwardBy: take
            )
            request.remainingBodyBytes -= take

            guard request.remainingBodyBytes == 0 else {
                activeRequest = request
                return false
            }

            // Declared-too-large bodies are consumed, then answered
            // 413 with the request's own keep-alive, mirroring stock.
            writePreparedGeneral(
                dispatcher.payloadTooLarge,
                sequence: request.sequence,
                method: request.method,
                isHeadRequest: request.isHeadRequest,
                version: request.version,
                keepAlive: request.keepAlive,
                context: context
            )
            activeRequest = nil
            return true
        }

        // Incremental limit check in stock's exact form: the verdict
        // is independent of read-chunk boundaries.
        if take
            > maxRequestBodyBytes
                - request.receivedBodyBytes
        {
            request.body.clear()
            request.discardingBody = true
            cumulation.moveReaderIndex(
                forwardBy: take
            )
            request.remainingBodyBytes -= take

            guard request.remainingBodyBytes == 0 else {
                activeRequest = request
                return false
            }

            writePreparedGeneral(
                dispatcher.payloadTooLarge,
                sequence: request.sequence,
                method: request.method,
                isHeadRequest: request.isHeadRequest,
                version: request.version,
                keepAlive: request.keepAlive,
                context: context
            )
            activeRequest = nil
            return true
        }

        var slice = cumulation.readSlice(
            length: take
        )!
        request.body.writeBuffer(&slice)
        request.receivedBodyBytes += take
        request.remainingBodyBytes -= take

        guard request.remainingBodyBytes == 0 else {
            activeRequest = request
            return false
        }

        completeBufferedRequest(
            request,
            context: context
        )
        activeRequest = nil
        return true
    }

    private func consumeChunkedBody(
        _ request: inout ActiveRequest,
        context: ChannelHandlerContext
    ) -> Bool {
        while true {
            let event: WTHTTP1ChunkEvent

            do {
                event = try parser.parseChunk(
                    from: &cumulation,
                    state: &request.chunkState
                )
            } catch {
                activeRequest = nil
                writeBadRequestAndClose(
                    context: context
                )
                return true
            }

            switch event {
            case .needMoreData:
                activeRequest = request
                return false

            case .data(var slice):
                let chunkBytes = slice.readableBytes

                if request.discardingBody {
                    continue
                }

                if chunkBytes
                    > maxRequestBodyBytes
                        - request.receivedBodyBytes
                {
                    request.body.clear()
                    request.discardingBody = true
                    continue
                }

                request.body.writeBuffer(&slice)
                request.receivedBodyBytes +=
                    chunkBytes

            case .end:
                if request.discardingBody {
                    writePreparedGeneral(
                        dispatcher.payloadTooLarge,
                        sequence: request.sequence,
                        method: request.method,
                        isHeadRequest: request.isHeadRequest,
                        version: request.version,
                        keepAlive: request.keepAlive,
                        context: context
                    )
                    activeRequest = nil
                    return true
                }

                completeBufferedRequest(
                    request,
                    context: context
                )
                activeRequest = nil
                return true
            }
        }
    }

    private func completeBufferedRequest(
        _ request: ActiveRequest,
        context: ChannelHandlerContext
    ) {
        if request.streamingUnsupported {
            writeUnsupportedStreaming(
                sequence: request.sequence,
                method: request.method,
                isHeadRequest: request.isHeadRequest,
                version: request.version,
                keepAlive: request.keepAlive,
                context: context
            )
            return
        }

        if let preResolvedAction =
            request.preResolvedAction
        {
            writePreResolved(
                preResolvedAction,
                nioHead: request.head,
                body: request.body,
                sequence: request.sequence,
                method: request.method,
                isHeadRequest: request.isHeadRequest,
                version: request.version,
                keepAlive: request.keepAlive,
                context: context
            )
            return
        }

        writeDispatchResult(
            dispatcher.dispatchPipeline(
                RuntimeRequest(
                    head: request.head,
                    body: request.body,
                    remoteAddress: context.channel
                        .remoteAddress
                ),
                context.eventLoop
            ),
            sequence: request.sequence,
            method: request.method,
            isHeadRequest: request.isHeadRequest,
            version: request.version,
            keepAlive: request.keepAlive,
            context: context
        )
    }

    private func writePreResolved(
        _ action: RuntimeRouteAction,
        nioHead: HTTPRequestHead,
        body: ByteBuffer,
        sequence: Int,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        switch action {
        case .prepared(let storage):
            writePreparedGeneral(
                storage,
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .sync(let syncAction):
            writeSyncGeneral(
                syncAction.run(
                    RuntimeRequest(
                        head: nioHead,
                        body: body
                    )
                ),
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .async(let asyncAction):
            writeFuture(
                asyncAction.run(
                    RuntimeRequest(
                        head: nioHead,
                        body: body,
                        remoteAddress: context.channel
                            .remoteAddress
                    ),
                    context.eventLoop
                ),
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .streaming:
            // Unreachable: streaming actions resolve to
            // `streamingUnsupported` before a pre-resolved action is
            // stored. Answered 500 like any other unsupported
            // streaming route.
            writeUnsupportedStreaming(
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
        }
    }

    private func writeDispatchResult(
        _ result: RuntimeDispatchResult,
        sequence: Int,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        switch result {
        case .response(let response):
            writeSyncGeneral(
                response,
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .prepared(let storage):
            writePreparedGeneral(
                storage,
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .future(let future):
            writeFuture(
                future,
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )
        }
    }

    private func writePreparedFast(
        _ storage: RuntimePreparedResponse,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        context: ChannelHandlerContext
    ) {
        let sequence = nextSequence
        nextSequence += 1

        // CONNECT uses the general path: its framing differs from
        // the sealed GET-like bytes.
        if method != .connect,
            let sealed = sealedFastResponse(
                storage,
                context: context
            )
        {
            var bytes = sealed.headBytes

            if !isHeadRequest {
                var body = sealed.bodyBytes
                bytes.writeBuffer(&body)
            }

            emit(
                bytes: bytes,
                sequence: sequence,
                closeAfter: false,
                context: context
            )
            return
        }

        writePreparedGeneral(
            storage,
            sequence: sequence,
            method: method,
            isHeadRequest: isHeadRequest,
            version: .http11,
            keepAlive: true,
            context: context
        )
    }

    private func writePreparedGeneral(
        _ storage: RuntimePreparedResponse,
        sequence: Int? = nil,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        let sequence =
            sequence ?? claimSequence()

        // Sealed bytes cover HTTP/1.1 keep-alive for every method but
        // CONNECT, mirroring stock's `http11Head` fast path; anything
        // else serializes the storage's response view, mirroring
        // stock's general `write(storage.response)` path.
        if
            version == .http11,
            keepAlive,
            method != .connect,
            let sealed = sealedFastResponse(
                storage,
                context: context
            )
        {
            var bytes = sealed.headBytes

            if !isHeadRequest {
                var body = sealed.bodyBytes
                bytes.writeBuffer(&body)
            }

            emit(
                bytes: bytes,
                sequence: sequence,
                closeAfter: false,
                context: context
            )
            return
        }

        writeSerialized(
            serializeResponse(
                storage.response,
                method: method,
                version: version,
                keepAlive: keepAlive,
                allocator: context.channel.allocator
            ),
            sequence: sequence,
            method: method,
            isHeadRequest: isHeadRequest,
            version: version,
            keepAlive: keepAlive,
            context: context
        )
    }

    private func writeSyncMinimal(
        _ response: RuntimeResponse,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        context: ChannelHandlerContext
    ) {
        writeSerialized(
            serializeResponse(
                response,
                method: method,
                version: .http11,
                keepAlive: true,
                allocator: context.channel.allocator
            ),
            sequence: claimSequence(),
            method: method,
            isHeadRequest: isHeadRequest,
            version: .http11,
            keepAlive: true,
            context: context
        )
    }

    private func writeSyncGeneral(
        _ response: RuntimeResponse,
        sequence: Int? = nil,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        writeSerialized(
            serializeResponse(
                response,
                method: method,
                version: version,
                keepAlive: keepAlive,
                allocator: context.channel.allocator
            ),
            sequence: sequence ?? claimSequence(),
            method: method,
            isHeadRequest: isHeadRequest,
            version: version,
            keepAlive: keepAlive,
            context: context
        )
    }

    private func writeFuture(
        _ future: EventLoopFuture<RuntimeResponse>,
        sequence: Int? = nil,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        let sequence = sequence ?? claimSequence()

        future
            .hop(to: context.eventLoop)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                guard context.channel.isActive else {
                    return
                }

                switch result {
                case .success(let response):
                    self.writeSyncGeneral(
                        response,
                        sequence: sequence,
                        method: method,
                        isHeadRequest: isHeadRequest,
                        version: version,
                        keepAlive: keepAlive,
                        context: context
                    )

                case .failure(let error):
                    self.writeFailure(
                        error,
                        sequence: sequence,
                        method: method,
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
        sequence: Int,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        switch dispatcher.mapError(
            error,
            context.eventLoop,
            context.channel.remoteAddress
        ) {
        case .response(let response):
            writeSyncGeneral(
                response,
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .future(let future):
            // Mirrors stock: the mapped future is already on-loop,
            // so no hop precedes completion.
            future
                .assumeIsolatedUnsafeUnchecked()
                .whenComplete { result in
                    switch result {
                    case .success(let response):
                        self.writeSyncGeneral(
                            response,
                            sequence: sequence,
                            method: method,
                            isHeadRequest: isHeadRequest,
                            version: version,
                            keepAlive: keepAlive,
                            context: context
                        )

                    case .failure:
                        self.writePreparedGeneral(
                            self.dispatcher
                                .internalServerError,
                            sequence: sequence,
                            method: method,
                            isHeadRequest: isHeadRequest,
                            version: version,
                            keepAlive: keepAlive,
                            context: context
                        )
                    }
                }
        }
    }

    private func writeUnsupportedStreaming(
        sequence: Int,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        writePreparedGeneral(
            dispatcher.internalServerError,
            sequence: sequence,
            method: method,
            isHeadRequest: isHeadRequest,
            version: version,
            keepAlive: keepAlive,
            context: context
        )
    }

    private func writeSerialized(
        _ serialized: SerializedResponse,
        sequence: Int,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        switch serialized {
        case .bytes(let bytes):
            emit(
                bytes: bytes,
                sequence: sequence,
                closeAfter: !keepAlive,
                context: context
            )

        case .unsupportedBody:
            // Tier 1 serves fileRegion/stream bodies as 500 without
            // invoking the producer; stock would serve them.
            writePreparedGeneral(
                dispatcher.internalServerError,
                sequence: sequence,
                method: method,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive,
                context: context
            )

        case .invalid:
            // Mirrors NIO's outbound validator drop: nothing valid
            // can be written, so the connection closes silently.
            closeSilently(context: context)
        }
    }

    private func rejectRequestEarly(
        _ storage: RuntimePreparedResponse,
        sequence: Int,
        method: WTHTTP1Method,
        isHeadRequest: Bool,
        version: WTHTTP1Version,
        context: ChannelHandlerContext
    ) {
        writePreparedGeneral(
            storage,
            sequence: sequence,
            method: method,
            isHeadRequest: isHeadRequest,
            version: version,
            keepAlive: false,
            context: context
        )
    }

    private func writeContinue(
        context: ChannelHandlerContext
    ) {
        var bytes = context.channel.allocator.buffer(
            capacity: 25
        )
        WTHTTP1ResponseWriter.writeContinue(
            into: &bytes
        )
        context.writeAndFlush(
            wrapOutboundOut(bytes),
            promise: nil
        )
    }

    private func writeBadRequestAndClose(
        context: ChannelHandlerContext
    ) {
        // Byte-exact mirror of HTTPServerProtocolErrorHandler: HTTP/1.1
        // 400 with capitalized Connection-first headers. The drain
        // loop exits via `closed`; the channel closes after flush,
        // mirroring stock's ByteToMessageDecoder close.
        var bytes = context.channel.allocator.buffer(
            capacity: Self.badRequestBytes.count
        )
        bytes.writeBytes(Self.badRequestBytes)
        closed = true
        activeRequest = nil
        heldResponses = nil
        cumulation.clear()

        context
            .writeAndFlush(
                wrapOutboundOut(bytes)
            )
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { _ in
                context.close(promise: nil)
            }
    }

    private func closeSilently(
        context: ChannelHandlerContext
    ) {
        closed = true
        activeRequest = nil
        heldResponses = nil
        cumulation.clear()
        context.close(promise: nil)
    }

    private func claimSequence() -> Int {
        let sequence = nextSequence
        nextSequence += 1
        return sequence
    }

    /// Ordered emission, mirroring `HTTPServerPipelineHandler`:
    /// pipelined responses leave in request order even when an
    /// earlier request completes asynchronously after a later one.
    /// The queue stays nil until a response actually arrives
    /// out of order.
    private func emit(
        bytes: ByteBuffer,
        sequence: Int,
        closeAfter: Bool,
        context: ChannelHandlerContext
    ) {
        // Late async completions after a close must not write.
        guard !closed else {
            return
        }

        guard sequence != emitSequence else {
            writeAndMaybeClose(
                bytes,
                closeAfter: closeAfter,
                context: context
            )

            guard !closed else {
                return
            }

            emitSequence += 1

            while let held = heldResponses?[
                emitSequence
            ] {
                heldResponses?[
                    emitSequence
                ] = nil
                writeAndMaybeClose(
                    held.bytes,
                    closeAfter: held.closeAfter,
                    context: context
                )

                guard !closed else {
                    return
                }

                emitSequence += 1
            }

            if heldResponses?.isEmpty == true {
                heldResponses = nil
            }

            return
        }

        if heldResponses == nil {
            heldResponses = [:]
        }

        heldResponses?[
            sequence
        ] = HeldResponse(
            bytes: bytes,
            closeAfter: closeAfter
        )
    }

    private func writeAndMaybeClose(
        _ bytes: ByteBuffer,
        closeAfter: Bool,
        context: ChannelHandlerContext
    ) {
        guard closeAfter else {
            context.writeAndFlush(
                wrapOutboundOut(bytes),
                promise: nil
            )
            return
        }

        // Mirrors `finishResponse(keepAlive: false)`: anything still
        // held or cumulated dies with the connection, matching stock
        // close semantics for pipelined requests.
        closed = true
        activeRequest = nil
        heldResponses = nil
        cumulation.clear()

        context
            .writeAndFlush(
                wrapOutboundOut(bytes)
            )
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { _ in
                context.close(promise: nil)
            }
    }

    private func sealedFastResponse(
        _ storage: RuntimePreparedResponse,
        context: ChannelHandlerContext
    ) -> WTHTTP1SealedResponse? {
        // Keyed by storage identity: fixed responses (413/417/500)
        // share this path with route responses, so a route seal
        // must never serve a fixed storage or vice versa.
        if
            cachedSealedOwner
                == ObjectIdentifier(storage),
            let cachedSealedResponse
        {
            return cachedSealedResponse
        }

        // Prepared storages are normalized by construction (their
        // response view claims `contentLengthIsNormalized`), so the
        // seal trusts framing exactly like stock's `http11Head`
        // path, which emits the stored head untouched.
        var headers: [(name: [UInt8], value: [UInt8])] = []
        headers.reserveCapacity(
            Int(storage.headers.count)
        )

        for (name, value) in storage.headers {
            headers.append((
                name: Array(name.utf8),
                value: Array(value.utf8)
            ))
        }

        guard
            let sealed = WTHTTP1ResponseSealer.seal(
                head: WTHTTP1ResponseHead(
                    statusCode: Int(storage.status.code),
                    reasonBytes: Array(
                        storage.status.reasonPhrase
                            .utf8
                    ),
                    headers: headers
                ),
                version: .http11,
                keepAlive: true,
                mayHaveBody: storage.status
                    .mayHaveResponseBody,
                contentLength: storage.bodyBuffer?
                    .readableBytes ?? 0,
                body: storage.bodyBuffer,
                trustFraming: true,
                allocator: context.channel.allocator
            )
        else {
            return nil
        }

        cachedSealedResponse = sealed
        cachedSealedOwner = ObjectIdentifier(
            storage
        )
        return sealed
    }

    private func serializeResponse(
        _ response: RuntimeResponse,
        method: WTHTTP1Method,
        version: WTHTTP1Version,
        keepAlive: Bool,
        allocator: ByteBufferAllocator
    ) -> SerializedResponse {
        let bodyBuffer: ByteBuffer?
        let bodyLength: Int

        switch response.body {
        case .empty:
            bodyBuffer = nil
            bodyLength = 0

        case .text(let value):
            var buffer = allocator.buffer(
                capacity: value.utf8.count
            )
            buffer.writeString(value)
            bodyLength = buffer.readableBytes
            bodyBuffer = buffer

        case .bytes(let bytes):
            var buffer = allocator.buffer(
                capacity: bytes.count
            )
            buffer.writeBytes(bytes)
            bodyLength = buffer.readableBytes
            bodyBuffer = buffer

        case .buffer(let value):
            bodyLength = value.readableBytes
            bodyBuffer = value

        case .fileRegion, .stream:
            return .unsupportedBody
        }

        var headers: [(name: [UInt8], value: [UInt8])] = []
        headers.reserveCapacity(
            Int(response.headers.count)
        )

        for (name, value) in response.headers {
            headers.append((
                name: Array(name.utf8),
                value: Array(value.utf8)
            ))
        }

        var out = allocator.buffer(capacity: 256)
        let written = WTHTTP1ResponseWriter.write(
            head: WTHTTP1ResponseHead(
                statusCode: Int(response.status.code),
                reasonBytes: Array(
                    response.status.reasonPhrase.utf8
                ),
                headers: headers
            ),
            version: version,
            keepAlive: keepAlive,
            mayHaveBody: response.status
                .mayHaveResponseBody,
            requestMethod: method,
            contentLength: bodyLength,
            body: bodyBuffer,
            trustFraming: response
                .contentLengthIsNormalized,
            into: &out
        )

        guard written else {
            return .invalid
        }

        return .bytes(out)
    }

    @inline(__always)
    private func requestHasMinimalHeaders(
        _ head: WTHTTP1RequestHead
    ) -> Bool {
        guard head.version == .http11 else {
            return false
        }

        switch head.headerCount {
        case 0:
            return true

        case 1:
            return isHostHeaderName(
                head.headerName(at: 0)
            )

        default:
            return false
        }
    }

    @inline(__always)
    private func isHostHeaderName(
        _ name: [UInt8]
    ) -> Bool {
        guard name.count == 4 else {
            return false
        }

        return foldedASCIILowercase(name[0]) == 104
            && foldedASCIILowercase(name[1]) == 111
            && foldedASCIILowercase(name[2]) == 115
            && foldedASCIILowercase(name[3]) == 116
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
    private func lookupTransportCached(
        _ nioHead: HTTPRequestHead,
        method: WTHTTP1Method,
        uri: [UInt8]
    ) -> RuntimeRouteAction {
        if
            cachedRouteMethod == method,
            cachedRouteURI == uri,
            let cachedRouteAction
        {
            return cachedRouteAction
        }

        let action = dispatcher.lookup(nioHead)

        cachedRouteMethod = method
        cachedRouteURI = uri
        cachedRouteAction = action
        cachedSealedResponse = nil
        cachedSealedOwner = nil

        return action
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

    /// Tier 1 boundary conversion: one NIO request head per request.
    /// This is the known conversion tax the experiment measures; the
    /// dispatcher contract itself is unchanged.
    private func convertHead(
        _ head: WTHTTP1RequestHead,
        method: WTHTTP1Method,
        uri: [UInt8]
    ) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        headers.reserveCapacity(head.headerCount)

        for index in 0..<head.headerCount {
            headers.add(
                name: String(
                    decoding: head.headerName(
                        at: index
                    ),
                    as: UTF8.self
                ),
                value: String(
                    decoding: head.headerValue(
                        at: index
                    ),
                    as: UTF8.self
                )
            )
        }

        return HTTPRequestHead(
            version: methodVersion(head.version),
            method: convertMethod(method),
            uri: String(
                decoding: uri,
                as: UTF8.self
            ),
            headers: headers
        )
    }

    private func methodVersion(
        _ version: WTHTTP1Version
    ) -> HTTPVersion {
        switch version {
        case .http11:
            return .http1_1

        case .http10:
            return .http1_0
        }
    }

    private func convertMethod(
        _ method: WTHTTP1Method
    ) -> HTTPMethod {
        switch method {
        case .get:
            return .GET

        case .put:
            return .PUT

        case .acl:
            return .ACL

        case .head:
            return .HEAD

        case .post:
            return .POST

        case .copy:
            return .COPY

        case .lock:
            return .LOCK

        case .move:
            return .MOVE

        case .bind:
            return .BIND

        case .link:
            return .LINK

        case .patch:
            return .PATCH

        case .trace:
            return .TRACE

        case .mkcol:
            return .MKCOL

        case .merge:
            return .MERGE

        case .purge:
            return .PURGE

        case .notify:
            return .NOTIFY

        case .search:
            return .SEARCH

        case .unlock:
            return .UNLOCK

        case .rebind:
            return .REBIND

        case .unbind:
            return .UNBIND

        case .report:
            return .REPORT

        case .delete:
            return .DELETE

        case .unlink:
            return .UNLINK

        case .connect:
            return .CONNECT

        case .msearch:
            return .MSEARCH

        case .options:
            return .OPTIONS

        case .propfind:
            return .PROPFIND

        case .checkout:
            return .CHECKOUT

        case .propatch:
            return .PROPPATCH

        case .subscribe:
            return .SUBSCRIBE

        case .mkcalendar:
            return .MKCALENDAR

        case .mkactivity:
            return .MKACTIVITY

        case .unsubscribe:
            return .UNSUBSCRIBE

        case .source:
            return .SOURCE

        case .custom(let raw):
            // Unreachable: the parser rejects unknown methods to
            // match llhttp, but the mapping stays total.
            return .RAW(
                value: String(
                    decoding: raw,
                    as: UTF8.self
                )
            )
        }
    }
}

private enum SerializedResponse {
    case bytes(ByteBuffer)
    case unsupportedBody
    case invalid
}
