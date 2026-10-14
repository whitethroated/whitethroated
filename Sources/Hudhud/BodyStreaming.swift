import NIOCore
import NIOHTTP1

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
    public typealias ChunkHandler = @Sendable (
        ByteBuffer
    ) -> EventLoopFuture<Void>?

    public typealias EndHandler = @Sendable ()
        -> EventLoopFuture<Response>

    internal let chunkHandler: ChunkHandler
    internal let endHandler: EndHandler

    public init(
        onChunk: @escaping ChunkHandler,
        onEnd: @escaping EndHandler
    ) {
        self.chunkHandler = onChunk
        self.endHandler = onEnd
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
    private let responsePromise: EventLoopPromise<Response>
    private var finished = false

    init(
        consumer: BodyStreamConsumer,
        eventLoop: EventLoop
    ) {
        self.consumer = consumer
        self.responsePromise = eventLoop.makePromise(
            of: Response.self
        )
    }

    var responseFuture: EventLoopFuture<Response> {
        responsePromise.futureResult
    }

    @inline(__always)
    func receive(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void>? {
        guard !finished else {
            return nil
        }

        return consumer.chunkHandler(buffer)
    }

    func finish() {
        guard !finished else {
            return
        }

        finished = true
        responsePromise.completeWith(
            consumer.endHandler()
        )
    }

    func fail(_ error: Error) {
        guard !finished else {
            return
        }

        finished = true
        responsePromise.fail(error)
    }
}

internal final class StreamingRegistration: @unchecked Sendable {
    internal enum State {
        case pending
        case session(BodyStreamSession)
        case bypass
        case cancelled(Error)
    }

    private let readyPromise: EventLoopPromise<Void>
    private var state: State = .pending

    init(eventLoop: EventLoop) {
        self.readyPromise = eventLoop.makePromise(
            of: Void.self
        )
    }

    var readyFuture: EventLoopFuture<Void> {
        readyPromise.futureResult
    }

    var currentState: State {
        state
    }

    func register(_ session: BodyStreamSession) {
        switch state {
        case .pending:
            state = .session(session)
            readyPromise.succeed(())

        case .cancelled(let error):
            session.fail(error)

        case .session, .bypass:
            preconditionFailure(
                "Streaming session registered more than once"
            )
        }
    }

    func bypassIfPending() {
        guard case .pending = state else {
            return
        }

        state = .bypass
        readyPromise.succeed(())
    }

    func cancel(_ error: Error) {
        switch state {
        case .pending:
            state = .cancelled(error)
            readyPromise.succeed(())

        case .session(let session):
            state = .cancelled(error)
            session.fail(error)

        case .bypass, .cancelled:
            break
        }
    }
}

internal struct StreamingTransportStart {
    let result: ResponderResult
    let registration: StreamingRegistration
    let maxBodyBytes: Int
}
