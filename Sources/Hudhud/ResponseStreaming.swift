import NIOCore
import NIOHTTP1

public enum ResponseStreamError: Error, Sendable, Equatable {
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

internal final class ResponseStreamLengthTracker:
    @unchecked Sendable
{
    let expected: Int
    private(set) var written = 0
    private(set) var failure: ResponseStreamError?

    init(expected: Int) {
        self.expected = expected
    }

    @inline(__always)
    func record(_ bytes: Int) -> ResponseStreamError? {
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
            let error = ResponseStreamError
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
    func completionError() -> ResponseStreamError? {
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

public struct ResponseStream: @unchecked Sendable {
    public typealias Producer = @Sendable (
        ResponseStreamWriter
    ) -> EventLoopFuture<Void>

    public typealias ErrorHandler = @Sendable (
        Error
    ) -> Void

    internal let producer: Producer
    internal let errorHandler: ErrorHandler?

    internal init(
        producer: @escaping Producer,
        errorHandler: ErrorHandler?
    ) {
        self.producer = producer
        self.errorHandler = errorHandler
    }
}

public struct ResponseStreamWriter: @unchecked Sendable {
    private let context: ChannelHandlerContext
    private let lengthTracker: ResponseStreamLengthTracker?

    internal init(
        context: ChannelHandlerContext,
        lengthTracker: ResponseStreamLengthTracker? = nil
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

    @discardableResult
    public func write(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

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

        return write(buffer)
    }

    @discardableResult
    public func writeAndFlush(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        requireEventLoop()

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

        return writeAndFlush(buffer)
    }

    public func flush() {
        requireEventLoop()
        context.flush()
    }

    @inline(__always)
    private func record(
        _ bytes: Int
    ) -> ResponseStreamError? {
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
