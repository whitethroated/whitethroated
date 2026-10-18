import NIOCore
import NIOHTTP1

import WhiteThroatedHTTP1

/// Default Tier 1 HTTP/1 connection handler for applications without
/// request-streaming routes.
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
/// transport retains at the module boundary.
///
/// Documented Tier 1 divergences (all fail safe, never permissive):
/// - Request-streaming routes are answered 500
///   (`internalServerError`, keep-alive preserved) without invoking
///   the consumer; stock would stream. A 413 still wins when a body
///   limit is exceeded first. Automatic transport mode never sends
///   such apps here.
/// - CONNECT and bodyless-status response streams suppress the
///   producer (clean head, no body); stock would run it into
///   encoder drops or raw framing garbage.
/// - A producer write after its stream ended closes the connection;
///   stock would emit protocol garbage past the end marker.
/// - An error handler that answers a stream-length failure with
///   another invalid stream gets 500 (single mapping per request);
///   stock recurses until it overflows or ping-pongs.
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
    public typealias OutboundIn = IOData
    public typealias OutboundOut = IOData

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
        var region: FileRegion?
        var closeAfter: Bool
        var buffered: Bool
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
    private var draining = false
    private var readPending = false

    private var nextSequence = 0
    private var emitSequence = 0
    private var heldResponses: [Int: HeldResponse]?

    // Response-stream state, all nil until the first stream. At most
    // one stream head is on the wire at a time (`openStreamSequence`
    // gates every later response, mirroring the stock pipelining
    // handler's in-order guarantee); the end watermark turns
    // post-end producer writes into a clean close (the NIO encoder
    // errors the connection there).
    private var tier1Streams: [Int: Tier1StreamState]?
    private var openStreamSequence: Int?
    private var maxEndedStreamSeq: Int?

    // Request sequences that already consumed their error mapping
    // for a stream-length failure. Without this, an error handler
    // that returns another invalid stream would recurse forever
    // (stock stack-overflows or ping-pongs here); Tier 1 fails safe
    // with 500 instead.
    internal private(set) var streamValidationFailed: Set<Int>?

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
        closed = true
        activeRequest = nil
        heldResponses = nil
        cumulation.clear()
        dropTier1Streams()
        readPending = false
        context.fireChannelInactive()
    }

    /// Match stock pipelining assistance: after a request body ends,
    /// withhold socket reads until its response ends. Already received
    /// bytes remain in cumulation, without dispatching later handlers.
    public func read(context: ChannelHandlerContext) {
        guard !closed else { return }
        if waitingForResponse {
            readPending = true
        } else {
            context.read()
        }
    }

    private var waitingForResponse: Bool {
        activeRequest == nil
            && (nextSequence != emitSequence || openStreamSequence != nil)
    }

    public func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        closed = true
        dropTier1Streams()
        context.close(promise: nil)
    }

    /// Parses and dispatches as far as the cumulated bytes allow:
    /// head, then body if any, then the next pipelined head. Stops on
    /// need-more-data or on a fatal (close the connection).
    private func drain(
        context: ChannelHandlerContext
    ) {
        // A synchronous response may complete inside beginRequest or
        // body consumption. Let the outer drain finish updating that
        // state before parsing another request.
        guard !draining else { return }
        draining = true
        defer {
            draining = false
            if readPending, !closed, !waitingForResponse {
                readPending = false
                context.read()
            }
        }

        while !closed {
            if activeRequest == nil {
                guard !waitingForResponse else {
                    compactCumulation()
                    return
                }
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
            clearCompletedStreamValidationFailure(sequence)

        case .future(let future):
            future
                .hop(to: context.eventLoop)
                .assumeIsolatedUnsafeUnchecked()
                .whenComplete { result in
                    guard !self.closed, context.channel.isActive else { return }
                    defer { self.clearCompletedStreamValidationFailure(sequence) }
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

    /// Error mapping may itself return an invalid stream or a pending
    /// future. Keep its recursion guard until a response head has actually
    /// emitted (or the connection closes), then release the request key.
    /// This is called only on error paths, never ordinary responses.
    private func clearCompletedStreamValidationFailure(_ sequence: Int) {
        guard closed || sequence < emitSequence else { return }
        streamValidationFailed?.remove(sequence)
        if streamValidationFailed?.isEmpty == true {
            streamValidationFailed = nil
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

        case .bytesWithRegion(let bytes, let region):
            emit(
                bytes: bytes,
                region: region,
                sequence: sequence,
                closeAfter: !keepAlive,
                context: context
            )

        case .streamPending(let pending):
            writeTier1Stream(
                pending,
                sequence: sequence,
                context: context
            )

        case .streamFailed(let error):
            if streamValidationFailed?.contains(sequence)
                == true
            {
                // The error handler already ran for this request
                // and produced another invalid stream: fail safe
                // with 500 instead of recursing forever.
                writePreparedGeneral(
                    dispatcher.internalServerError,
                    sequence: sequence,
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )
            } else {
                if streamValidationFailed == nil {
                    streamValidationFailed = []
                }

                streamValidationFailed?.insert(sequence)
                writeFailure(
                    error,
                    sequence: sequence,
                    method: method,
                    isHeadRequest: isHeadRequest,
                    version: version,
                    keepAlive: keepAlive,
                    context: context
                )
            }

        case .unsupportedBody:
            // Tier 1 serves bodies it cannot frame as 500 without
            // invoking the producer; stock serves them.
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

    /// Emits a validated stream head in sequence; the producer
    /// starts when the head releases (unless suppressed). The head
    /// is buffered like stock's (`write`, not `writeAndFlush`):
    /// the first flush is the stream end, an explicit flush, or a
    /// flushing chunk write. Ordering mirrors the stock pipelining
    /// handler: the open stream gates every later response, and the
    /// end releases them.
    private func writeTier1Stream(
        _ pending: Tier1PendingStream,
        sequence: Int,
        context: ChannelHandlerContext
    ) {
        var endBytes = context.channel.allocator.buffer(
            capacity: 5
        )

        if pending.chunked, !pending.suppressProducer {
            endBytes.writeStaticString("0\r\n\r\n")
        }

        let state = Tier1StreamState(
            chunked: pending.chunked,
            endBytes: endBytes,
            endCloseAfter: !pending.streamKeepAlive,
            stream: pending.suppressProducer
                ? nil : pending.stream,
            tracker: pending.tracker
        )

        if tier1Streams == nil {
            tier1Streams = [:]
        }

        tier1Streams?[sequence] = state

        emit(
            bytes: pending.headBytes,
            sequence: sequence,
            closeAfter: false,
            buffered: true,
            context: context
        )

        // A late async completion after a close must not start the
        // producer (stock guards channel-active the same way).
        guard !closed else {
            tier1Streams?[sequence] = nil
            return
        }

        guard !pending.suppressProducer else {
            streamEnded(
                sequence: sequence,
                state: state,
                context: context
            )
            return
        }
    }

    /// Runs the producer after its head released, mirroring stock
    /// (head `write`, then produce, then chunks). Runs exactly once
    /// per stream.
    private func startTier1Producer(
        _ stream: RuntimeResponseStream,
        tracker: RuntimeStreamLengthTracker?,
        sequence: Int,
        context: ChannelHandlerContext
    ) {
        // A release racing a close must not start the producer.
        guard !closed else {
            tier1Streams?[sequence] = nil
            return
        }

        let sink = RuntimeStreamChunkSink(
            eventLoop: context.eventLoop,
            allocator: context.channel.allocator,
            closeFuture: context.channel.closeFuture,
            writeBody: { data in
                self.tier1WriteBody(
                    data,
                    sequence: sequence,
                    context: context
                )
            },
            writeBodyAndFlush: { data in
                self.tier1WriteBodyAndFlush(
                    data,
                    sequence: sequence,
                    context: context
                )
            },
            flush: {
                context.flush()
            }
        )
        let writer = RuntimeStreamWriter(
            sink: sink,
            lengthTracker: tracker
        )

        stream.produce(writer).hop(to: context.eventLoop)
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                self.tier1ProducerCompleted(
                    result,
                    sequence: sequence,
                    stream: stream,
                    tracker: tracker,
                    context: context
                )
            }
    }

    private func tier1WriteBody(
        _ data: IOData,
        sequence: Int,
        context: ChannelHandlerContext
    ) {
        // Writes to a dead channel are dropped (the stock writer
        // returns success for fire-and-forget writes there too).
        guard !closed, context.channel.isActive else {
            return
        }

        guard let state = tier1Streams?[sequence] else {
            // Ended (a post-end write errors the connection, like
            // the NIO encoder) or dropped on close (drop silently).
            if let maxEnded = maxEndedStreamSeq,
                sequence <= maxEnded
            {
                closeSilently(context: context)
            }

            return
        }

        // The head is still held behind an earlier response: hold
        // the fragment too (stock holds out-of-order parts).
        guard state.headReleased else {
            state.pending.append(data)
            return
        }

        writeTier1Chunk(
            data,
            state: state,
            context: context
        )
    }

    private func tier1WriteBodyAndFlush(
        _ data: IOData,
        sequence: Int,
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        guard !closed, context.channel.isActive else {
            return context.eventLoop.makeFailedFuture(
                ChannelError.ioOnClosedChannel
            )
        }

        guard let state = tier1Streams?[sequence] else {
            if let maxEnded = maxEndedStreamSeq,
                sequence <= maxEnded
            {
                closeSilently(context: context)
            }

            return context.eventLoop.makeFailedFuture(
                ChannelError.ioOnClosedChannel
            )
        }

        // Held fragments report success at accept; they flush when
        // the head releases and always by stream completion.
        guard state.headReleased else {
            state.pending.append(data)

            return context.eventLoop
                .makeSucceededVoidFuture()
        }

        if state.chunked {
            guard data.readableBytes > 0 else {
                // Unframed empties still flush honestly: zero bytes
                // with a real flush future (mirrors NIO's
                // promise-passing zero write).
                return context.writeAndFlush(
                    wrapOutboundOut(
                        .byteBuffer(
                            context.channel.allocator
                                .buffer(capacity: 0)
                        )
                    )
                )
            }

            var line = context.channel.allocator.buffer(
                capacity: 32
            )
            line.writeString(
                String(data.readableBytes, radix: 16)
            )
            line.writeStaticString("\r\n")
            context.write(
                wrapOutboundOut(.byteBuffer(line)),
                promise: nil
            )
            context.write(
                wrapOutboundOut(data),
                promise: nil
            )
            line.moveReaderIndex(
                forwardBy: line.readableBytes - 2
            )

            return context.writeAndFlush(
                wrapOutboundOut(.byteBuffer(line))
            )
        }

        return context.writeAndFlush(
            wrapOutboundOut(data)
        )
    }

    /// Frames one fragment exactly like NIO's chunk writer: empty
    /// chunked fragments are skipped (framing one would end the
    /// stream), lowercase hex length, shared-storage trailing CRLF.
    private func writeTier1Chunk(
        _ data: IOData,
        state: Tier1StreamState,
        context: ChannelHandlerContext
    ) {
        guard state.chunked else {
            context.write(
                wrapOutboundOut(data),
                promise: nil
            )
            return
        }

        guard data.readableBytes > 0 else {
            return
        }

        var line = context.channel.allocator.buffer(
            capacity: 32
        )
        line.writeString(
            String(data.readableBytes, radix: 16)
        )
        line.writeStaticString("\r\n")
        context.write(
            wrapOutboundOut(.byteBuffer(line)),
            promise: nil
        )
        context.write(
            wrapOutboundOut(data),
            promise: nil
        )
        line.moveReaderIndex(
            forwardBy: line.readableBytes - 2
        )
        context.write(
            wrapOutboundOut(.byteBuffer(line)),
            promise: nil
        )
    }

    private func tier1ProducerCompleted(
        _ result: Result<Void, Error>,
        sequence: Int,
        stream: RuntimeResponseStream,
        tracker: RuntimeStreamLengthTracker?,
        context: ChannelHandlerContext
    ) {
        guard context.channel.isActive, !closed else {
            return
        }

        guard let state = tier1Streams?[sequence] else {
            return
        }

        switch result {
        case .success:
            if let error = tracker?.completionError() {
                stream.onError?(error)
                flushAndCloseForStreamError(
                    context: context
                )
                return
            }

            streamEnded(
                sequence: sequence,
                state: state,
                context: context
            )

        case .failure(let error):
            stream.onError?(error)
            flushAndCloseForStreamError(
                context: context
            )
        }
    }

    /// Writes the end marker (or nothing) and releases everything
    /// the open stream gated. When the head is still held, the end
    /// waits for it so head, chunks, and end stay ordered.
    private func streamEnded(
        sequence: Int,
        state: Tier1StreamState,
        context: ChannelHandlerContext
    ) {
        guard state.headReleased else {
            state.endPending = true
            return
        }

        let endBytes = state.endBytes
        let closeAfter = state.endCloseAfter

        tier1Streams?[sequence] = nil

        if let maxEnded = maxEndedStreamSeq {
            maxEndedStreamSeq = max(maxEnded, sequence)
        } else {
            maxEndedStreamSeq = sequence
        }

        writeAndMaybeClose(
            endBytes,
            closeAfter: closeAfter,
            context: context
        )

        guard !closed else {
            return
        }

        if openStreamSequence == sequence {
            openStreamSequence = nil
        }

        cascadeHeldResponses(context: context)

        if heldResponses?.isEmpty == true {
            heldResponses = nil
        }

        if !draining {
            drain(context: context)
        }
    }

    /// Releases a stream head onto the wire: opens the stream gate,
    /// starts the producer (stock order: head write, then produce),
    /// then emits a pre-requested end.
    private func streamHeadEmitted(
        _ sequence: Int,
        context: ChannelHandlerContext
    ) {
        guard let state = tier1Streams?[sequence],
            !state.headReleased
        else {
            return
        }

        // Structural: the open-stream gate holds every later head,
        // so no other stream can be open when this head emits.
        assert(openStreamSequence == nil)
        openStreamSequence = sequence
        state.headReleased = true

        for data in state.pending {
            writeTier1Chunk(
                data,
                state: state,
                context: context
            )
        }

        state.pending.removeAll(keepingCapacity: false)

        if !state.producerStarted,
            let stream = state.stream
        {
            state.producerStarted = true
            state.stream = nil
            let tracker = state.tracker
            state.tracker = nil
            startTier1Producer(
                stream,
                tracker: tracker,
                sequence: sequence,
                context: context
            )
        }

        if state.endPending {
            streamEnded(
                sequence: sequence,
                state: state,
                context: context
            )
        }
    }

    /// Flushes accepted bytes, then closes (mirrors the stock
    /// producer-failure path).
    private func flushAndCloseForStreamError(
        context: ChannelHandlerContext
    ) {
        context.flush()
        closeSilently(context: context)
    }

    /// Releases held responses in order. Shared by the emit fast
    /// path and by stream completion.
    private func cascadeHeldResponses(
        context: ChannelHandlerContext
    ) {
        while let held = heldResponses?[emitSequence] {
            heldResponses?[emitSequence] = nil

            let released = emitSequence

            if held.buffered {
                // A held stream head buffers like an in-order one;
                // its end or an explicit flush moves it.
                context.write(
                    wrapOutboundOut(
                        .byteBuffer(held.bytes)
                    ),
                    promise: nil
                )
            } else {
                writeAndMaybeClose(
                    held.bytes,
                    region: held.region,
                    closeAfter: held.closeAfter,
                    context: context
                )
            }

            guard !closed else {
                return
            }

            emitSequence += 1
            streamHeadEmitted(released, context: context)

            guard !closed else {
                return
            }

            // A freshly opened stream owns the wire: later held
            // responses wait for its end marker (releasing them
            // here would interleave them with stream chunks).
            guard openStreamSequence == nil else {
                return
            }
        }
    }

    /// Drops all stream tracking (close paths only).
    private func dropTier1Streams() {
        tier1Streams = nil
        openStreamSequence = nil
        maxEndedStreamSeq = nil
        streamValidationFailed = nil
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
            wrapOutboundOut(.byteBuffer(bytes)),
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
        dropTier1Streams()

        context
            .writeAndFlush(
                wrapOutboundOut(.byteBuffer(bytes))
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
        dropTier1Streams()
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
        region: FileRegion? = nil,
        sequence: Int,
        closeAfter: Bool,
        buffered: Bool = false,
        context: ChannelHandlerContext
    ) {
        // Late async completions after a close must not write.
        guard !closed else {
            return
        }

        // An open stream owns the wire until its end marker (the
        // stock pipelining handler holds later responses the same
        // way); without this gate a pipelined response could
        // interleave with stream chunks.
        if let open = openStreamSequence, sequence > open {
            holdResponse(
                bytes: bytes,
                region: region,
                sequence: sequence,
                closeAfter: closeAfter,
                buffered: buffered
            )
            return
        }

        guard sequence != emitSequence else {
            if buffered {
                // Stream heads buffer like stock's head `write`:
                // the stream end or an explicit flush moves them.
                context.write(
                    wrapOutboundOut(
                        .byteBuffer(bytes)
                    ),
                    promise: nil
                )
            } else {
                writeAndMaybeClose(
                    bytes,
                    region: region,
                    closeAfter: closeAfter,
                    context: context
                )
            }

            guard !closed else {
                return
            }

            emitSequence += 1
            streamHeadEmitted(sequence, context: context)

            guard !closed else {
                return
            }

            cascadeHeldResponses(context: context)

            if heldResponses?.isEmpty == true {
                heldResponses = nil
            }

            if !draining {
                drain(context: context)
            }

            return
        }

        holdResponse(
            bytes: bytes,
            region: region,
            sequence: sequence,
            closeAfter: closeAfter,
            buffered: buffered
        )
    }

    private func holdResponse(
        bytes: ByteBuffer,
        region: FileRegion?,
        sequence: Int,
        closeAfter: Bool,
        buffered: Bool = false
    ) {
        if heldResponses == nil {
            heldResponses = [:]
        }

        heldResponses?[
            sequence
        ] = HeldResponse(
            bytes: bytes,
            region: region,
            closeAfter: closeAfter,
            buffered: buffered
        )
    }

    private func writeAndMaybeClose(
        _ bytes: ByteBuffer,
        region: FileRegion? = nil,
        closeAfter: Bool,
        context: ChannelHandlerContext
    ) {
        guard closeAfter else {
            if let region {
                context.write(
                    wrapOutboundOut(.byteBuffer(bytes)),
                    promise: nil
                )
                context.writeAndFlush(
                    wrapOutboundOut(.fileRegion(region)),
                    promise: nil
                )
            } else {
                context.writeAndFlush(
                    wrapOutboundOut(.byteBuffer(bytes)),
                    promise: nil
                )
            }

            return
        }

        // Mirrors `finishResponse(keepAlive: false)`: anything still
        // held or cumulated dies with the connection, matching stock
        // close semantics for pipelined requests.
        closed = true
        activeRequest = nil
        heldResponses = nil
        cumulation.clear()
        dropTier1Streams()

        if region != nil {
            context.write(
                wrapOutboundOut(.byteBuffer(bytes)),
                promise: nil
            )
        }

        context
            .writeAndFlush(
                region.map {
                    wrapOutboundOut(
                        .fileRegion($0)
                    )
                } ?? wrapOutboundOut(.byteBuffer(bytes))
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

        case .fileRegion(let region):
            return fileRegionResponse(
                region,
                response: response,
                method: method,
                version: version,
                keepAlive: keepAlive,
                allocator: allocator
            )

        case .stream(let stream):
            return streamPendingResponse(
                stream,
                response: response,
                method: method,
                version: version,
                keepAlive: keepAlive,
                allocator: allocator
            )
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

    /// Zero-copy file response: the head carries the region length
    /// as Content-Length and the region itself flows to the channel
    /// untouched. HEAD/CONNECT and bodyless statuses keep the head
    /// but suppress the region, mirroring the NIO encoder.
    private func fileRegionResponse(
        _ region: FileRegion,
        response: RuntimeResponse,
        method: WTHTTP1Method,
        version: WTHTTP1Version,
        keepAlive: Bool,
        allocator: ByteBufferAllocator
    ) -> SerializedResponse {
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
            contentLength: region.readableBytes,
            body: nil,
            trustFraming: response
                .contentLengthIsNormalized,
            into: &out
        )

        guard written else {
            return .invalid
        }

        let suppressBody =
            method == .head || method == .connect
        let stripFraming =
            !response.status.mayHaveResponseBody
            || method == .connect

        // Empty regions carry zero bytes; stock never emits them
        // as outbound messages, so neither does Tier 1.
        guard !suppressBody, !stripFraming,
            region.readableBytes > 0
        else {
            return .bytes(out)
        }

        return .bytesWithRegion(out, region)
    }

    /// Validates a response stream and serializes its head, mirroring
    /// the stock streaming writer plus the NIO encoder's framing
    /// decision: declared length resolves identically (trusted fast
    /// path or header scan), the head carries identical framing and
    /// Connection tokens, and chunk-vs-raw follows the encoder rule
    /// (Content-Length present means raw, otherwise HTTP/1.1 means
    /// chunked).
    private func streamPendingResponse(
        _ stream: RuntimeResponseStream,
        response: RuntimeResponse,
        method: WTHTTP1Method,
        version: WTHTTP1Version,
        keepAlive: Bool,
        allocator: ByteBufferAllocator
    ) -> SerializedResponse {
        let declared: Int?

        if response.contentLengthIsNormalized,
            let expected = stream.expectedContentLength
        {
            declared = expected
        } else {
            switch RuntimeResponseWriter
                .declaredStreamContentLength(
                    headers: response.headers
                )
            {
            case .success(let length):
                declared = length

            case .failure(let error):
                stream.onError?(error)
                return .streamFailed(error)
            }
        }

        let tracker = declared.map {
            RuntimeStreamLengthTracker(expected: $0)
        }
        let streamKeepAlive =
            keepAlive
            && (version != .http10 || tracker != nil)

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
            keepAlive: streamKeepAlive,
            mayHaveBody: response.status
                .mayHaveResponseBody,
            requestMethod: method,
            contentLength: declared,
            body: nil,
            trustFraming: false,
            leaveBodyOpen: true,
            into: &out
        )

        guard written else {
            return .invalid
        }

        // Framing keys off the declared length (which the repair
        // above wrote into the head), so head and framing can never
        // disagree: unknown length chunks on HTTP/1.1, everything
        // else flows raw. (A lying direct construction with a
        // trusted length but inconsistent headers normalizes to the
        // declared value; stock passes such garbage through.)
        let chunked =
            version == .http11 && declared == nil

        // HEAD never runs the producer (stock-identical). CONNECT
        // and bodyless statuses suppress it too: stock would run it
        // into encoder drops or raw garbage, while Tier 1 fails safe
        // with a clean head (documented intentional divergence).
        let suppressProducer =
            method == .head
            || method == .connect
            || !response.status.mayHaveResponseBody

        return .streamPending(
            Tier1PendingStream(
                stream: stream,
                tracker: tracker,
                headBytes: out,
                chunked: chunked,
                streamKeepAlive: streamKeepAlive,
                suppressProducer: suppressProducer
            )
        )
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
    case bytesWithRegion(ByteBuffer, FileRegion)
    case streamPending(Tier1PendingStream)
    case streamFailed(RuntimeStreamError)
    case unsupportedBody
    case invalid
}

/// Live Tier 1 response-stream state, keyed by head sequence.
/// Event-loop confined; entries are removed when the stream ends.
private final class Tier1StreamState {
    /// Frame each fragment (`len CRLF data CRLF`) vs raw.
    let chunked: Bool

    /// Terminal (`0 CRLF CRLF`) or empty end bytes, fixed at stream
    /// start.
    let endBytes: ByteBuffer

    /// Close after the end marker (vs keep-alive).
    let endCloseAfter: Bool

    /// True once the head hits the wire. The producer starts at
    /// release (stock runs it after the head write), so fragments
    /// written before that are unexpected; `pending` holds them as
    /// a safety net rather than dropping bytes.
    var headReleased = false

    /// Fragments written while the head was still held (defensive;
    /// unreachable while produce starts at release).
    var pending: [IOData] = []

    /// The end was requested before the head hit the wire (HEAD
    /// suppression on a held head); it goes out at release.
    var endPending = false

    /// The validated stream, consumed when the producer starts at
    /// head release. Nil for suppressed producers (never started).
    var stream: RuntimeResponseStream?

    /// Length contract for the deferred producer start.
    var tracker: RuntimeStreamLengthTracker?

    /// True once the producer has started (exactly once).
    var producerStarted = false

    init(
        chunked: Bool,
        endBytes: ByteBuffer,
        endCloseAfter: Bool,
        stream: RuntimeResponseStream?,
        tracker: RuntimeStreamLengthTracker?
    ) {
        self.chunked = chunked
        self.endBytes = endBytes
        self.endCloseAfter = endCloseAfter
        self.stream = stream
        self.tracker = tracker
    }
}

/// A validated Tier 1 stream ready to emit: head bytes plus the
/// framing contract the producer must follow.
private struct Tier1PendingStream {
    var stream: RuntimeResponseStream
    var tracker: RuntimeStreamLengthTracker?
    var headBytes: ByteBuffer
    var chunked: Bool
    var streamKeepAlive: Bool
    var suppressProducer: Bool
}
