import NIOCore
import NIOHTTP1
import WhiteThroatedRuntime

public struct StreamRequest: @unchecked Sendable {
    private let request: Request

    internal init(_ request: Request) {
        self.request = request
    }

    public var method: HTTPMethod {
        request.method
    }

    public var uri: String {
        request.uri
    }

    public var headers: HTTPHeaders {
        request.headers
    }

    public var path: String {
        request.path
    }

    public var queryString: String? {
        request.queryString
    }

    public var parameters: [String: String] {
        request.parameters
    }

    public var queryParameters: [String: String] {
        request.queryParameters
    }

    public func parameter(_ name: String) -> String? {
        request.parameter(name)
    }

    public func query(_ name: String) -> String? {
        request.query(name)
    }

    public func header(_ name: String) -> String? {
        request.header(name)
    }

    public func cookie(_ name: String) -> String? {
        request.cookie(name)
    }
}

public struct BodyStreamConsumer: @unchecked Sendable {
    public typealias SyncChunkHandler = @Sendable (
        ByteBuffer
    ) -> Void

    public typealias ThrowingSyncChunkHandler = @Sendable (
        ByteBuffer
    ) throws -> Void

    public typealias ChunkHandler = @Sendable (
        ByteBuffer
    ) -> EventLoopFuture<Void>?

    public typealias EndHandler = @Sendable ()
        -> EventLoopFuture<Response>

    public typealias SyncEndHandler = @Sendable ()
        -> Response

    public typealias ThrowingSyncEndHandler = @Sendable ()
        throws -> Response

    public typealias ErrorHandler = @Sendable (
        Error
    ) -> Void

    internal enum ChunkResponder: @unchecked Sendable {
        case synchronous(SyncChunkHandler)
        case throwingSynchronous(
            ThrowingSyncChunkHandler
        )
        case asynchronous(ChunkHandler)
    }

    internal enum EndResponder: @unchecked Sendable {
        case synchronous(SyncEndHandler)
        case throwingSynchronous(
            ThrowingSyncEndHandler
        )
        case asynchronous(EndHandler)
    }

    internal let chunkResponder: ChunkResponder
    internal let endResponder: EndResponder
    internal let errorHandler: ErrorHandler?

    public init(
        onChunk: @escaping SyncChunkHandler,
        onEnd: @escaping EndHandler,
        onError: ErrorHandler? = nil
    ) {
        self.chunkResponder = .synchronous(onChunk)
        self.endResponder = .asynchronous(onEnd)
        self.errorHandler = onError
    }

    public init(
        onChunk: @escaping SyncChunkHandler,
        onEnd: @escaping SyncEndHandler,
        onError: ErrorHandler? = nil
    ) {
        self.chunkResponder = .synchronous(onChunk)
        self.endResponder = .synchronous(onEnd)
        self.errorHandler = onError
    }

    public init(
        onChunkThrowing:
            @escaping ThrowingSyncChunkHandler,
        onEnd: @escaping EndHandler,
        onError: ErrorHandler? = nil
    ) {
        self.chunkResponder =
            .throwingSynchronous(
                onChunkThrowing
            )
        self.endResponder = .asynchronous(onEnd)
        self.errorHandler = onError
    }

    public init(
        onChunkThrowing:
            @escaping ThrowingSyncChunkHandler,
        onEnd: @escaping SyncEndHandler,
        onError: ErrorHandler? = nil
    ) {
        self.chunkResponder =
            .throwingSynchronous(
                onChunkThrowing
            )
        self.endResponder = .synchronous(onEnd)
        self.errorHandler = onError
    }


    public init(
        onChunkThrowing:
            @escaping ThrowingSyncChunkHandler,
        onEndThrowing:
            @escaping ThrowingSyncEndHandler,
        onError: ErrorHandler? = nil
    ) {
        self.chunkResponder =
            .throwingSynchronous(
                onChunkThrowing
            )
        self.endResponder =
            .throwingSynchronous(
                onEndThrowing
            )
        self.errorHandler = onError
    }

    public init(
        onChunk: @escaping ChunkHandler,
        onEnd: @escaping EndHandler,
        onError: ErrorHandler? = nil
    ) {
        self.chunkResponder = .asynchronous(onChunk)
        self.endResponder = .asynchronous(onEnd)
        self.errorHandler = onError
    }

    public init(
        onChunk: @escaping ChunkHandler,
        onEnd: @escaping SyncEndHandler,
        onError: ErrorHandler? = nil
    ) {
        self.chunkResponder = .asynchronous(onChunk)
        self.endResponder = .synchronous(onEnd)
        self.errorHandler = onError
    }
}

public typealias StreamingHandler = @Sendable (
    StreamRequest,
    Context
) -> BodyStreamConsumer

public enum BodyStreamError: Error, Sendable {
    case payloadTooLarge
    case connectionClosed
}

internal final class BodyStreamSession: @unchecked Sendable {
    private let consumer: BodyStreamConsumer
    private let eventLoop: EventLoop
    private let responsePromise: EventLoopPromise<Response>
    private var finished = false

    init(
        consumer: BodyStreamConsumer,
        eventLoop: EventLoop
    ) {
        self.consumer = consumer
        self.eventLoop = eventLoop
        self.responsePromise = eventLoop.makePromise(
            of: Response.self
        )
    }

    var responseFuture: EventLoopFuture<Response> {
        responsePromise.futureResult
    }

    /// Bridges this framework session onto the runtime pump. The
    /// runtime session owns the returned object graph through its
    /// closures; callers must bridge exactly once per session.
    func bridgeToRuntime() -> RuntimeStreamSession {
        RuntimeStreamSession(
            consumer: RuntimeStreamConsumer(
                onChunk: { [self] buffer in
                    try self.receive(buffer)
                },
                onFinish: { [self] in
                    self.finish()
                    return self.responseFuture.map {
                        $0.runtimeResponse
                    }
                },
                onError: { [self] error in
                    self.fail(
                        mapRuntimeRequestStreamError(
                            error
                        )
                    )
                }
            ),
            eventLoop: eventLoop
        )
    }

    @inline(__always)
    func receive(
        _ buffer: ByteBuffer
    ) throws -> EventLoopFuture<Void>? {
        guard !finished else {
            return nil
        }

        switch consumer.chunkResponder {
        case .synchronous(let handler):
            handler(buffer)
            return nil

        case .throwingSynchronous(let handler):
            try handler(buffer)
            return nil

        case .asynchronous(let handler):
            return handler(buffer)
        }
    }

    func finish() {
        guard !finished else {
            return
        }

        finished = true

        switch consumer.endResponder {
        case .synchronous(let handler):
            responsePromise.succeed(
                handler()
            )

        case .throwingSynchronous(let handler):
            do {
                responsePromise.succeed(
                    try handler()
                )
            } catch {
                consumer.errorHandler?(error)
                responsePromise.fail(error)
            }

        case .asynchronous(let handler):
            responsePromise.completeWith(
                handler()
            )
        }
    }

    func fail(_ error: Error) {
        guard !finished else {
            return
        }

        finished = true
        consumer.errorHandler?(error)
        responsePromise.fail(error)
    }
}

// Streaming registration and transport-start state moved to
// WhiteThroatedRuntime (RuntimeStreamRegistration,
// RuntimeStreamingStart). Framework sessions bridge onto the runtime
// pump via BodyStreamSession.bridgeToRuntime().
