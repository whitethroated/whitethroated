import NIOCore

/// Transport-side request-stream errors. Framework adapters map these
/// onto user-facing stream errors at the boundary (cold paths only).
public enum RuntimeRequestStreamError: Error, Sendable {
    case payloadTooLarge
    case connectionClosed
}

/// Framework-provided stream consumer, boxed as closures.
///
/// Built once per streaming request by framework dispatch. The
/// closures capture the framework consumer session; the runtime pump
/// below drives them without knowing framework types.
public struct RuntimeStreamConsumer: @unchecked Sendable {
    /// Returns a future when asynchronous backpressure applies, or
    /// nil when the chunk was consumed synchronously.
    public var onChunk:
        @Sendable (ByteBuffer) throws
            -> EventLoopFuture<Void>?
    public var onFinish:
        @Sendable () -> EventLoopFuture<RuntimeResponse>
    public var onError:
        (@Sendable (Error) -> Void)?

    public init(
        onChunk: @escaping @Sendable (ByteBuffer) throws
            -> EventLoopFuture<Void>?,
        onFinish: @escaping @Sendable ()
            -> EventLoopFuture<RuntimeResponse>,
        onError: (@Sendable (Error) -> Void)? = nil
    ) {
        self.onChunk = onChunk
        self.onFinish = onFinish
        self.onError = onError
    }
}

/// Transport-side body stream session: completion promise plus
/// finished-state guard. All methods run on the connection loop.
public final class RuntimeStreamSession: @unchecked Sendable {
    private let consumer: RuntimeStreamConsumer
    private let responsePromise:
        EventLoopPromise<RuntimeResponse>
    private var finished = false

    public init(
        consumer: RuntimeStreamConsumer,
        eventLoop: EventLoop
    ) {
        self.consumer = consumer
        self.responsePromise = eventLoop.makePromise(
            of: RuntimeResponse.self
        )
    }

    public var responseFuture:
        EventLoopFuture<RuntimeResponse>
    {
        responsePromise.futureResult
    }

    @inline(__always)
    public func receive(
        _ buffer: ByteBuffer
    ) throws -> EventLoopFuture<Void>? {
        guard !finished else {
            return nil
        }

        return try consumer.onChunk(buffer)
    }

    public func finish() {
        guard !finished else {
            return
        }

        finished = true
        responsePromise.completeWith(
            consumer.onFinish()
        )
    }

    public func fail(_ error: Error) {
        guard !finished else {
            return
        }

        finished = true
        consumer.onError?(error)
        responsePromise.fail(error)
    }
}

/// Transport-side registration state machine. Tracks whether the
/// framework attached a streaming session, bypassed streaming for a
/// buffered result, or cancelled the request.
public final class RuntimeStreamRegistration:
    @unchecked Sendable
{
    public enum State {
        case pending
        case session(RuntimeStreamSession)
        case bypass
        case cancelled(Error)
    }

    private let readyPromise: EventLoopPromise<Void>
    private var state: State = .pending

    public init(eventLoop: EventLoop) {
        self.readyPromise = eventLoop.makePromise(
            of: Void.self
        )
    }

    public var readyFuture: EventLoopFuture<Void> {
        readyPromise.futureResult
    }

    public var currentState: State {
        state
    }

    public func register(
        _ session: RuntimeStreamSession
    ) {
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

    public func bypassIfPending() {
        guard case .pending = state else {
            return
        }

        state = .bypass
        readyPromise.succeed(())
    }

    public func cancel(_ error: Error) {
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

/// Streaming-start handoff from framework dispatch to the runtime
/// pump: the initial dispatch result plus registration and limits.
public struct RuntimeStreamingStart: @unchecked Sendable {
    public var result: RuntimeDispatchResult
    public var registration: RuntimeStreamRegistration
    public var maxBodyBytes: Int
    public var declaredBodyTooLarge: Bool

    public init(
        result: RuntimeDispatchResult,
        registration: RuntimeStreamRegistration,
        maxBodyBytes: Int,
        declaredBodyTooLarge: Bool
    ) {
        self.result = result
        self.registration = registration
        self.maxBodyBytes = maxBodyBytes
        self.declaredBodyTooLarge = declaredBodyTooLarge
    }
}
