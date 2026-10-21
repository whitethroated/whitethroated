import CZlib
import NIOCore

/// One-shot gzip encoding over zlib's deflate.
///
/// gzip framing is selected with a `15 + 16` window size. Each call
/// owns a fresh `z_stream` and releases it before returning, so the
/// module keeps no compressor state between requests.
///
/// Returns `nil` when zlib initialization, deflate, or finalization
/// fails. Callers treat failure as "serve identity" rather than
/// failing the request.
internal enum ZlibGzip {
    static func compress(
        _ bytes: UnsafeRawBufferPointer,
        level: Int32
    ) -> ByteBuffer? {
        var stream = z_stream()

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

        defer {
            _ = deflateEnd(&stream)
        }

        let bound = Int(
            deflateBound(
                &stream,
                uLong(bytes.count)
            )
        )

        var output = ByteBufferAllocator().buffer(
            capacity: bound
        )

        var status: Int32 = Z_OK

        output.writeWithUnsafeMutableBytes(
            minimumWritableBytes: bound
        ) { destination in
            stream.next_in = UnsafeMutablePointer(
                mutating:
                    bytes
                    .bindMemory(to: UInt8.self)
                    .baseAddress
            )
            stream.avail_in = uInt(bytes.count)
            stream.next_out = destination
                .bindMemory(to: UInt8.self)
                .baseAddress
            stream.avail_out = uInt(
                destination.count
            )

            status = deflate(
                &stream,
                Z_FINISH
            )

            return Int(stream.total_out)
        }

        guard status == Z_STREAM_END else {
            return nil
        }

        return output
    }
}
