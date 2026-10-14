import NIOCore
import NIOHTTP1

public struct ResponseStream: @unchecked Sendable {
    public typealias Producer = @Sendable (
        ResponseStreamWriter
    ) -> EventLoopFuture<Void>

    internal let producer: Producer

    internal init(
        producer: @escaping Producer
    ) {
        self.producer = producer
    }
}

public struct ResponseStreamWriter: @unchecked Sendable {
    private let context: ChannelHandlerContext

    internal init(
        context: ChannelHandlerContext
    ) {
        self.context = context
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

        return context.write(
            NIOAny(
                HTTPServerResponsePart.body(
                    .byteBuffer(buffer)
                )
            )
        )
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

        return context.writeAndFlush(
            NIOAny(
                HTTPServerResponsePart.body(
                    .byteBuffer(buffer)
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
    private func requireEventLoop() {
        precondition(
            context.eventLoop.inEventLoop,
            "Response stream writes must occur on the channel event loop"
        )
    }
}
