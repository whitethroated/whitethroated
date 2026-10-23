import NIOCore
import NIOHTTP1
import WhiteThroatedRuntime

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

public struct ResponseStream: @unchecked Sendable {
    public typealias Producer = @Sendable (
        ResponseStreamWriter
    ) -> EventLoopFuture<Void>

    public typealias SynchronousProducer =
        @Sendable (
            SynchronousResponseStreamWriter
        ) throws -> Void

    public typealias ErrorHandler = @Sendable (
        Error
    ) -> Void

    internal enum ProducerStorage:
        @unchecked Sendable
    {
        case asynchronous(Producer)
        case synchronous(SynchronousProducer)
    }

    internal let producer: ProducerStorage
    internal let errorHandler: ErrorHandler?
    internal let expectedContentLength: Int?

    internal init(
        producer: @escaping Producer,
        errorHandler: ErrorHandler?,
        expectedContentLength: Int? = nil
    ) {
        self.producer = .asynchronous(producer)
        self.errorHandler = errorHandler
        self.expectedContentLength =
            expectedContentLength
    }

    internal init(
        synchronousProducer:
            @escaping SynchronousProducer,
        errorHandler: ErrorHandler?,
        expectedContentLength: Int? = nil
    ) {
        self.producer =
            .synchronous(
                synchronousProducer
            )
        self.errorHandler = errorHandler
        self.expectedContentLength =
            expectedContentLength
    }
}

/// Developer-facing response stream writer. Thin boundary wrapper
/// over the runtime writer: length tracking, event-loop checks, and
/// emission all live in WhiteThroatedRuntime. Failures surface as
/// `ResponseStreamError` to preserve the public API contract.
public struct ResponseStreamWriter: @unchecked Sendable {
    private let runtimeWriter: RuntimeStreamWriter

    internal init(
        runtimeWriter: RuntimeStreamWriter
    ) {
        self.runtimeWriter =
            runtimeWriter.mappingErrors(
                mapRuntimeStreamError
            )
    }

    public var eventLoop: EventLoop {
        runtimeWriter.eventLoop
    }

    public var closeFuture: EventLoopFuture<Void> {
        runtimeWriter.closeFuture
    }

    public func makeBuffer(
        capacity: Int = 0
    ) -> ByteBuffer {
        runtimeWriter.makeBuffer(
            capacity: capacity
        )
    }

    @discardableResult
    public func write(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        runtimeWriter.write(buffer)
    }

    @discardableResult
    public func writeFileRegion(
        _ region: FileRegion
    ) -> EventLoopFuture<Void> {
        runtimeWriter.writeFileRegion(
            region
        )
    }

    @discardableResult
    public func writeString(
        _ value: String
    ) -> EventLoopFuture<Void> {
        runtimeWriter.writeString(value)
    }

    @discardableResult
    public func writeAndFlush(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        runtimeWriter.writeAndFlush(
            buffer
        )
    }

    @discardableResult
    public func writeFileRegionAndFlush(
        _ region: FileRegion
    ) -> EventLoopFuture<Void> {
        runtimeWriter
            .writeFileRegionAndFlush(
                region
            )
    }

    @discardableResult
    public func writeStringAndFlush(
        _ value: String
    ) -> EventLoopFuture<Void> {
        runtimeWriter.writeStringAndFlush(
            value
        )
    }

    public func flush() {
        runtimeWriter.flush()
    }
}


/// Developer-facing writer for synchronous response producers.
///
/// Writes enqueue directly on the connection event loop and do not
/// return an `EventLoopFuture` per chunk. This avoids producer-side
/// future chaining. Use the existing `ResponseStreamWriter` when
/// producer progress depends on asynchronous write completion or
/// future-based backpressure.
public struct SynchronousResponseStreamWriter:
    @unchecked Sendable
{
    private let runtimeWriter:
        RuntimeStreamWriter

    internal init(
        runtimeWriter: RuntimeStreamWriter
    ) {
        self.runtimeWriter =
            runtimeWriter.mappingErrors(
                mapRuntimeStreamError
            )
    }

    public func makeBuffer(
        capacity: Int = 0
    ) -> ByteBuffer {
        runtimeWriter.makeBuffer(
            capacity: capacity
        )
    }

    public func write(
        _ buffer: ByteBuffer
    ) throws {
        try runtimeWriter
            .writeSynchronously(buffer)
    }

    public func writeFileRegion(
        _ region: FileRegion
    ) throws {
        try runtimeWriter
            .writeFileRegionSynchronously(
                region
            )
    }

    public func writeString(
        _ value: String
    ) throws {
        try runtimeWriter
            .writeStringSynchronously(value)
    }

    public func flush() {
        runtimeWriter.flush()
    }
}
