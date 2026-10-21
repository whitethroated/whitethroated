import CZlib
import NIOHTTP1

/// Returns true when a response's `Vary` headers already cover the
/// `Accept-Encoding` token.
func varyContainsAcceptEncoding(
    _ headers: HTTPHeaders
) -> Bool {
    headers[canonicalForm: "vary"]
        .contains { value in
            value
                .lowercased()
                .contains("accept-encoding")
        }
}

/// Decompresses a gzip stream for round-trip assertions.
func inflateGzip(
    _ compressed: [UInt8]
) -> [UInt8]? {
    var stream = z_stream()

    guard
        inflateInit2_(
            &stream,
            15 + 16,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK
    else {
        return nil
    }

    defer {
        _ = inflateEnd(&stream)
    }

    var input = compressed
    var status: Int32 = Z_OK
    var output: [UInt8] = []

    input.withUnsafeMutableBufferPointer {
        inputBuffer in

        stream.next_in = inputBuffer.baseAddress
        stream.avail_in = uInt(inputBuffer.count)

        var chunk = [UInt8](
            repeating: 0,
            count: 4096
        )

        while status == Z_OK {
            let produced = chunk
                .withUnsafeMutableBytes {
                    destination -> Int in

                    stream.next_out = destination
                        .bindMemory(
                            to: UInt8.self
                        )
                        .baseAddress
                    stream.avail_out = uInt(
                        destination.count
                    )

                    status = inflate(
                        &stream,
                        Z_NO_FLUSH
                    )

                    return destination.count
                        - Int(stream.avail_out)
                }

            if produced > 0 {
                output.append(
                    contentsOf: chunk[0..<produced]
                )
            } else if
                status == Z_OK,
                stream.avail_in == 0
            {
                status = Z_BUF_ERROR
            }
        }
    }

    guard status == Z_STREAM_END else {
        return nil
    }

    return output
}

/// Decompresses the gzip bytes decoded so far without requiring the
/// member to be complete. Models an incremental client decoder that
/// reads up to a `Z_SYNC_FLUSH` boundary.
func inflateGzipPartial(
    _ compressed: [UInt8]
) -> [UInt8]? {
    var stream = z_stream()

    guard
        inflateInit2_(
            &stream,
            15 + 16,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK
    else {
        return nil
    }

    defer {
        _ = inflateEnd(&stream)
    }

    var input = compressed
    var output: [UInt8] = []

    input.withUnsafeMutableBufferPointer {
        inputBuffer in

        stream.next_in = inputBuffer.baseAddress
        stream.avail_in = uInt(inputBuffer.count)

        var chunk = [UInt8](
            repeating: 0,
            count: 4096
        )

        while true {
            let produced = chunk
                .withUnsafeMutableBytes {
                    destination -> Int in

                    stream.next_out = destination
                        .bindMemory(
                            to: UInt8.self
                        )
                        .baseAddress
                    stream.avail_out = uInt(
                        destination.count
                    )

                    _ = inflate(
                        &stream,
                        Z_NO_FLUSH
                    )

                    return destination.count
                        - Int(stream.avail_out)
                }

            guard produced > 0 else {
                break
            }

            output.append(
                contentsOf: chunk[0..<produced]
            )
        }
    }

    return output
}
