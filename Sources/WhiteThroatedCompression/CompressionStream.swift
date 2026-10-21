import CZlib
import NIOCore
import NIOHTTP1
import WhiteThroated

extension Compression {
    /// Event-loop-confined writer for `stream(for:...)` producers.
    ///
    /// Mirrors the compressible subset of `ResponseStreamWriter`.
    /// When compression applies, every write is deflated into the
    /// underlying writer; otherwise every call forwards unchanged.
    /// File-region writes are intentionally unavailable because a
    /// file region cannot be compressed in place.
    ///
    /// The struct is created inside one stream producer and only
    /// used from the event loop that runs that producer, which is
    /// the invariant behind its unchecked `Sendable` conformance.
    public struct StreamWriter: @unchecked Sendable {
        private let underlying: ResponseStreamWriter
        private let deflater: ZlibDeflateStream?

        internal init(
            underlying: ResponseStreamWriter,
            deflater: ZlibDeflateStream?
        ) {
            self.underlying = underlying
            self.deflater = deflater
        }

        public var eventLoop: EventLoop {
            underlying.eventLoop
        }

        public var closeFuture: EventLoopFuture<Void> {
            underlying.closeFuture
        }

        public func makeBuffer(
            capacity: Int = 0
        ) -> ByteBuffer {
            underlying.makeBuffer(
                capacity: capacity
            )
        }

        @discardableResult
        public func write(
            _ buffer: ByteBuffer
        ) -> EventLoopFuture<Void> {
            guard let deflater else {
                return underlying.write(buffer)
            }

            guard
                let compressed = deflater.encode(
                    buffer,
                    flush: Z_NO_FLUSH
                )
            else {
                return failedFuture()
            }

            guard compressed.readableBytes > 0 else {
                return succeededFuture()
            }

            return underlying.write(compressed)
        }

        @discardableResult
        public func writeString(
            _ value: String
        ) -> EventLoopFuture<Void> {
            guard deflater != nil else {
                return underlying.writeString(value)
            }

            var buffer = underlying.makeBuffer(
                capacity: value.utf8.count
            )
            buffer.writeString(value)

            return write(buffer)
        }

        @discardableResult
        public func writeAndFlush(
            _ buffer: ByteBuffer
        ) -> EventLoopFuture<Void> {
            guard let deflater else {
                return underlying.writeAndFlush(buffer)
            }

            guard
                let compressed = deflater.encode(
                    buffer,
                    flush: Z_SYNC_FLUSH
                )
            else {
                return failedFuture()
            }

            guard compressed.readableBytes > 0 else {
                underlying.flush()
                return succeededFuture()
            }

            return underlying.writeAndFlush(
                compressed
            )
        }

        @discardableResult
        public func writeStringAndFlush(
            _ value: String
        ) -> EventLoopFuture<Void> {
            guard deflater != nil else {
                return underlying
                    .writeStringAndFlush(value)
            }

            var buffer = underlying.makeBuffer(
                capacity: value.utf8.count
            )
            buffer.writeString(value)

            return writeAndFlush(buffer)
        }

        public func flush() {
            guard let deflater else {
                underlying.flush()
                return
            }

            guard
                let compressed = deflater.encode(
                    underlying.makeBuffer(
                        capacity: 0
                    ),
                    flush: Z_SYNC_FLUSH
                )
            else {
                return
            }

            guard compressed.readableBytes > 0 else {
                underlying.flush()
                return
            }

            _ = underlying.writeAndFlush(
                compressed
            )
        }

        private func failedFuture()
            -> EventLoopFuture<Void>
        {
            eventLoop.makeFailedFuture(
                CompressionError.compressionFailed
            )
        }

        private func succeededFuture()
            -> EventLoopFuture<Void>
        {
            eventLoop.makeSucceededVoidFuture()
        }
    }

    /// Builds a streamed response whose writes are compressed when
    /// the request negotiated a configured algorithm.
    ///
    /// The buffered middleware cannot compress streams because their
    /// bodies are written after the response head, so streaming
    /// compression is an explicit per-response API. The response is
    /// statically eligible when its status may carry a body and its
    /// declared content type matches the configured policy; a `nil`
    /// or disallowed content type streams identity. Statically
    /// eligible responses always carry `Vary: Accept-Encoding`.
    ///
    /// Negotiation is opportunistic like `encode(_:for:)`: a request
    /// that cannot receive a configured coding receives the identity
    /// stream rather than an error. Flush boundaries are preserved
    /// with `Z_SYNC_FLUSH`, and the gzip trailer is appended when the
    /// producer completes, so incremental decoders keep working.
    public func stream(
        for request: Request,
        contentType: String? = nil,
        status: HTTPResponseStatus = .ok,
        onError: ResponseStream.ErrorHandler? = nil,
        produce: @escaping @Sendable (
            StreamWriter
        ) -> EventLoopFuture<Void>
    ) -> Response {
        let staticallyEligible =
            status.mayHaveResponseBody
            && contentType.map {
                configuration.contentTypes
                    .allows($0)
            } == true

        guard staticallyEligible else {
            return streamResponse(
                contentType: contentType,
                status: status,
                onError: onError,
                deflaterLevel: nil,
                produce: produce
            )
        }

        switch negotiator.decide(
            headers: request.headers
        ) {
        case .algorithm(let index):
            var response = streamResponse(
                contentType: contentType,
                status: status,
                onError: onError,
                deflaterLevel: Int32(
                    configuration
                        .compressionLevel
                ),
                produce: produce
            )

            response.headers.replaceOrAdd(
                name: "content-encoding",
                value: configuration
                    .algorithms[index].rawValue
            )
            Self.appendVary(
                to: &response.headers
            )

            return response

        case .identity, .notAcceptable:
            var response = streamResponse(
                contentType: contentType,
                status: status,
                onError: onError,
                deflaterLevel: nil,
                produce: produce
            )

            Self.appendVary(
                to: &response.headers
            )

            return response
        }
    }

    private func streamResponse(
        contentType: String?,
        status: HTTPResponseStatus,
        onError: ResponseStream.ErrorHandler?,
        deflaterLevel: Int32?,
        produce: @escaping @Sendable (
            StreamWriter
        ) -> EventLoopFuture<Void>
    ) -> Response {
        Response.stream(
            contentType: contentType,
            status: status,
            onError: onError,
            produce: { writer in
                let deflater = deflaterLevel.flatMap {
                    ZlibDeflateStream(level: $0)
                }

                if
                    deflaterLevel != nil,
                    deflater == nil
                {
                    return writer.eventLoop
                        .makeFailedFuture(
                            CompressionError
                                .compressionFailed
                        )
                }

                let proxy = StreamWriter(
                    underlying: writer,
                    deflater: deflater
                )

                guard let deflater else {
                    return produce(proxy)
                }

                return produce(proxy).flatMap { _ in
                    guard
                        let tail = deflater.finish()
                    else {
                        return writer.eventLoop
                            .makeFailedFuture(
                                CompressionError
                                    .compressionFailed
                            )
                    }

                    guard tail.readableBytes > 0 else {
                        writer.flush()

                        return writer.eventLoop
                            .makeSucceededVoidFuture()
                    }

                    return writer.writeAndFlush(
                        tail
                    )
                }
            }
        )
    }
}
