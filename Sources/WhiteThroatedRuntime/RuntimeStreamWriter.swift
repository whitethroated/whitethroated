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

/// Event-loop-bound response stream writer. All methods must run on
/// the connection event loop.
public struct RuntimeStreamWriter: @unchecked Sendable {
    private let context: ChannelHandlerContext
    private let lengthTracker:
        RuntimeStreamLengthTracker?

    public init(
        context: ChannelHandlerContext,
        lengthTracker: RuntimeStreamLengthTracker? = nil
    ) {
        self.context = context
        self.lengthTracker = lengthTracker
    }

    public var eventLoop: EventLoop {
        context.eventLoop
    }

    public var closeFuture: EventLoopFuture<Void> {
        context.channel.closeFuture
    }

    public func makeBuffer(
        capacity: Int = 0
    ) -> ByteBuffer {
        requireEventLoop()
        precondition(
            capacity >= 0,
            "Buffer capacity must be zero or greater"
        )

        return context.channel.allocator.buffer(
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
            return context.eventLoop.makeFailedFuture(
                failure
            )
        }

        context.write(
            NIOAny(
                HTTPServerResponsePart.body(
                    .fileRegion(region)
                )
            ),
            promise: nil
        )

        return context.eventLoop
            .makeSucceededVoidFuture()
    }

    @discardableResult
    public func writeString(
        _ value: String
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

        var buffer =
            context.channel.allocator.buffer(
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
            return context.eventLoop.makeFailedFuture(
                failure
            )
        }

        return context.writeAndFlush(
            NIOAny(
                HTTPServerResponsePart.body(
                    .fileRegion(region)
                )
            )
        )
    }

    @discardableResult
    public func writeStringAndFlush(
        _ value: String
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

        var buffer =
            context.channel.allocator.buffer(
                capacity: value.utf8.count
            )
        buffer.writeString(value)

        return writeAndFlushChecked(buffer)
    }

    public func flush() {
        requireEventLoop()
        context.flush()
    }

    @inline(__always)
    private func writeChecked(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        if let failure = record(
            buffer.readableBytes
        ) {
            return context.eventLoop.makeFailedFuture(
                failure
            )
        }

        context.write(
            NIOAny(
                HTTPServerResponsePart.body(
                    .byteBuffer(buffer)
                )
            ),
            promise: nil
        )

        return context.eventLoop
            .makeSucceededVoidFuture()
    }

    @inline(__always)
    private func writeAndFlushChecked(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        if let failure = record(
            buffer.readableBytes
        ) {
            return context.eventLoop.makeFailedFuture(
                failure
            )
        }

        return context.writeAndFlush(
            NIOAny(
                HTTPServerResponsePart.body(
                    .byteBuffer(buffer)
                )
            )
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
            context.eventLoop.inEventLoop,
            "Response stream writes must occur on the channel event loop"
        )
    }
}
