import NIOCore
import NIOHTTP1

/// Transport-side response-stream errors. Framework adapters map these
/// onto user-facing stream errors at the boundary (cold paths only).
public enum RuntimeStreamError: Error, Sendable, Equatable {
    case invalidContentLength(String)
    case ambiguousContentLength([String])
    case contentLengthExceeded(
        expected: Int,
        attempted: Int
    )
    case contentLengthMismatch(
        expected: Int,
        actual: Int
    )
}

public final class RuntimeStreamLengthTracker:
    @unchecked Sendable
{
    public let expected: Int
    private(set) public var written = 0
    private(set) public var failure:
        RuntimeStreamError?

    public init(expected: Int) {
        self.expected = expected
    }

    @inline(__always)
    public func record(
        _ bytes: Int
    ) -> RuntimeStreamError? {
        guard failure == nil else {
            return failure
        }

        guard bytes >= 0 else {
            preconditionFailure(
                "Stream write byte count cannot be negative"
            )
        }

        if bytes > expected - written {
            let attempted =
                written > Int.max - bytes
                ? Int.max
                : written + bytes
            let error = RuntimeStreamError
                .contentLengthExceeded(
                    expected: expected,
                    attempted: attempted
                )

            failure = error
            return error
        }

        written += bytes
        return nil
    }

    @inline(__always)
    public func completionError() -> RuntimeStreamError? {
        if let failure {
            return failure
        }

        guard written == expected else {
            return .contentLengthMismatch(
                expected: expected,
                actual: written
            )
        }

        return nil
    }
}

/// Chunk emission strategy for response-stream producers.
///
/// The stock transport builds part-writing closures (response parts
/// flow through the NIO HTTP encoder); Tier 1 builds direct
/// chunk-framing closures (bytes flow straight to the channel).
/// Declared-length accounting and event-loop checks stay in
/// `RuntimeStreamWriter`, shared by both transports.
public struct RuntimeStreamChunkSink: @unchecked Sendable {
    /// Event loop chunk writes must run on.
    public var eventLoop: EventLoop

    /// Allocator for producer-owned buffers.
    public var allocator: ByteBufferAllocator

    /// Completes when the underlying channel closes.
    public var closeFuture: EventLoopFuture<Void>

    /// Emits one body fragment without flushing.
    public var writeBody:
        (IOData) -> Void

    /// Emits one body fragment and flushes.
    public var writeBodyAndFlush:
        (IOData) -> EventLoopFuture<Void>

    /// Flushes previously written fragments.
    public var flush:
        () -> Void

    /// Creates a sink from explicit closures.
    public init(
        eventLoop: EventLoop,
        allocator: ByteBufferAllocator,
        closeFuture: EventLoopFuture<Void>,
        writeBody:
            @escaping (IOData) -> Void,
        writeBodyAndFlush:
            @escaping (IOData)
                -> EventLoopFuture<Void>,
        flush:
            @escaping () -> Void
    ) {
        self.eventLoop = eventLoop
        self.allocator = allocator
        self.closeFuture = closeFuture
        self.writeBody = writeBody
        self.writeBodyAndFlush = writeBodyAndFlush
        self.flush = flush
    }
}

/// Event-loop-bound response stream writer. All methods must run on
/// the connection event loop.
public struct RuntimeStreamWriter: @unchecked Sendable {
    private let sink: RuntimeStreamChunkSink
    private let lengthTracker:
        RuntimeStreamLengthTracker?

    public init(
        context: ChannelHandlerContext,
        lengthTracker: RuntimeStreamLengthTracker? = nil
    ) {
        let eventLoop = context.eventLoop
        let allocator = context.channel.allocator
        let closeFuture = context.channel.closeFuture

        self.sink = RuntimeStreamChunkSink(
            eventLoop: eventLoop,
            allocator: allocator,
            closeFuture: closeFuture,
            writeBody: { data in
                context.write(
                    Self.part(data),
                    promise: nil
                )
            },
            writeBodyAndFlush: { data in
                context.writeAndFlush(
                    Self.part(data)
                )
            },
            flush: {
                context.flush()
            }
        )
        self.lengthTracker = lengthTracker
    }

    /// Creates a writer over an explicit chunk sink.
    ///
    /// Used by transports that frame chunks themselves (Tier 1).
    internal init(
        sink: RuntimeStreamChunkSink,
        lengthTracker: RuntimeStreamLengthTracker? = nil
    ) {
        self.sink = sink
        self.lengthTracker = lengthTracker
    }

    private static func part(_ data: IOData) -> NIOAny {
        switch data {
        case .byteBuffer(let buffer):
            NIOAny(
                HTTPServerResponsePart.body(
                    .byteBuffer(buffer)
                )
            )

        case .fileRegion(let region):
            NIOAny(
                HTTPServerResponsePart.body(
                    .fileRegion(region)
                )
            )
        }
    }

    public var eventLoop: EventLoop {
        sink.eventLoop
    }

    public var closeFuture: EventLoopFuture<Void> {
        sink.closeFuture
    }

    public func makeBuffer(
        capacity: Int = 0
    ) -> ByteBuffer {
        requireEventLoop()
        precondition(
            capacity >= 0,
            "Buffer capacity must be zero or greater"
        )

        return sink.allocator.buffer(
            capacity: capacity
        )
    }

    @discardableResult
    public func write(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        requireEventLoop()
        return writeChecked(buffer)
    }

    @discardableResult
    public func writeFileRegion(
        _ region: FileRegion
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

        if let failure = record(
            region.readableBytes
        ) {
            return sink.eventLoop.makeFailedFuture(
                failure
            )
        }

        sink.writeBody(.fileRegion(region))

        return sink.eventLoop
            .makeSucceededVoidFuture()
    }

    @discardableResult
    public func writeString(
        _ value: String
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

        var buffer =
            sink.allocator.buffer(
                capacity: value.utf8.count
            )
        buffer.writeString(value)

        return writeChecked(buffer)
    }

    @discardableResult
    public func writeAndFlush(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        requireEventLoop()
        return writeAndFlushChecked(buffer)
    }

    @discardableResult
    public func writeFileRegionAndFlush(
        _ region: FileRegion
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

        if let failure = record(
            region.readableBytes
        ) {
            return sink.eventLoop.makeFailedFuture(
                failure
            )
        }

        return sink.writeBodyAndFlush(
            .fileRegion(region)
        )
    }

    @discardableResult
    public func writeStringAndFlush(
        _ value: String
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

        var buffer =
            sink.allocator.buffer(
                capacity: value.utf8.count
            )
        buffer.writeString(value)

        return writeAndFlushChecked(buffer)
    }

    public func flush() {
        requireEventLoop()
        sink.flush()
    }

    @inline(__always)
    private func writeChecked(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        if let failure = record(
            buffer.readableBytes
        ) {
            return sink.eventLoop.makeFailedFuture(
                failure
            )
        }

        sink.writeBody(.byteBuffer(buffer))

        return sink.eventLoop
            .makeSucceededVoidFuture()
    }

    @inline(__always)
    private func writeAndFlushChecked(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        if let failure = record(
            buffer.readableBytes
        ) {
            return sink.eventLoop.makeFailedFuture(
                failure
            )
        }

        return sink.writeBodyAndFlush(
            .byteBuffer(buffer)
        )
    }

    @inline(__always)
    private func record(
        _ bytes: Int
    ) -> RuntimeStreamError? {
        lengthTracker?.record(bytes)
    }

    @inline(__always)
    private func requireEventLoop() {
        precondition(
            sink.eventLoop.inEventLoop,
            "Response stream writes must occur on the channel event loop"
        )
    }
}
