import CZlib
import NIOCore

/// Incremental gzip encoder over zlib's deflate for streamed
/// response bodies.
///
/// A deflate stream is created inside one response producer and is
/// only mutated from the connection event loop that runs that
/// producer, so no lock or actor protects it. `finish()` must be
/// called once after the last write; `deinit` releases zlib state
/// even when a producer fails or is discarded.
///
/// `@unchecked Sendable` records that confinement invariant: the
/// producer's futures and their callbacks run on the same connection
/// event loop that performs the writes.
internal final class ZlibDeflateStream: @unchecked Sendable {
    private var stream = z_stream()
    private let allocator: ByteBufferAllocator
    private var isFinished = false

    init?(
        level: Int32,
        allocator: ByteBufferAllocator =
            ByteBufferAllocator()
    ) {
        guard
            deflateInit2_(
                &stream,
                level,
                Z_DEFLATED,
                15 + 16,
                8,
                Z_DEFAULT_STRATEGY,
                zlibVersion(),
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK
        else {
            return nil
        }

        self.allocator = allocator
    }

    deinit {
        _ = deflateEnd(&stream)
    }

    /// Encodes `buffer` and returns the output currently available.
    ///
    /// `flush` controls how aggressively zlib emits pending output:
    /// `Z_NO_FLUSH` for ordinary writes, `Z_SYNC_FLUSH` when the
    /// caller needs the bytes written so far to be decodable.
    /// Returns `nil` on a zlib stream error.
    func encode(
        _ buffer: ByteBuffer,
        flush: Int32
    ) -> ByteBuffer? {
        guard !isFinished else {
            return nil
        }

        var output = allocator.buffer(
            capacity: Int(
                deflateBound(
                    &stream,
                    uLong(buffer.readableBytes)
                )
            ) + 64
        )

        let status: Int32

        if buffer.readableBytes > 0 {
            status = buffer.withUnsafeReadableBytes {
                bytes -> Int32 in

                stream.next_in = UnsafeMutablePointer(
                    mutating:
                        bytes
                        .bindMemory(to: UInt8.self)
                        .baseAddress
                )
                stream.avail_in = uInt(bytes.count)

                return pump(&output, flush: flush)
            }
        } else {
            stream.next_in = nil
            stream.avail_in = 0

            status = pump(&output, flush: flush)
        }

        guard Self.isSuccess(status) else {
            return nil
        }

        if status == Z_STREAM_END {
            isFinished = true
        }

        return output
    }

    /// Finalizes the gzip member and returns its trailer bytes.
    /// Returns `nil` when zlib fails to finish the stream.
    func finish() -> ByteBuffer? {
        guard !isFinished else {
            return allocator.buffer(capacity: 0)
        }

        var output = allocator.buffer(
            capacity: 64
        )

        stream.next_in = nil
        stream.avail_in = 0

        let status = pump(
            &output,
            flush: Z_FINISH
        )

        guard status == Z_STREAM_END else {
            return nil
        }

        isFinished = true

        return output
    }

    private func pump(
        _ output: inout ByteBuffer,
        flush: Int32
    ) -> Int32 {
        var status: Int32 = Z_OK

        while true {
            _ = output.writeWithUnsafeMutableBytes(
                minimumWritableBytes: 1024
            ) { destination -> Int in

                stream.next_out = destination
                    .bindMemory(to: UInt8.self)
                    .baseAddress
                stream.avail_out = uInt(
                    destination.count
                )

                status = deflate(
                    &stream,
                    flush
                )

                return destination.count
                    - Int(stream.avail_out)
            }

            if
                status == Z_OK,
                stream.avail_out == 0
            {
                continue
            }

            return status
        }
    }

    private static func isSuccess(
        _ status: Int32
    ) -> Bool {
        status == Z_OK
            || status == Z_BUF_ERROR
            || status == Z_STREAM_END
    }
}
