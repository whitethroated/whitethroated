import NIOCore

/// Response head owned by WhiteThroated: status, reason, and headers
/// as raw bytes. Produced by the Tier 1 boundary from dispatcher
/// output; consumed only by `WTHTTP1ResponseWriter`.
public struct WTHTTP1ResponseHead: Sendable {
    public var statusCode: Int
    public var reasonBytes: [UInt8]
    public var headers: [(name: [UInt8], value: [UInt8])]

    public init(
        statusCode: Int,
        reasonBytes: [UInt8],
        headers: [(name: [UInt8], value: [UInt8])] = []
    ) {
        self.statusCode = statusCode
        self.reasonBytes = reasonBytes
        self.headers = headers
    }
}

/// Direct response serializer: `WTHTTP1ResponseHead` to wire bytes.
///
/// Mirrors two oracles at once: the NIO encoder's byte format and
/// framing repair (differential-tested byte-exact), and the stock
/// runtime's connection-token behavior (handler-level equivalence
/// tests). Returns `false` and writes nothing when any name, value,
/// or reason byte is invalid, mirroring NIO's validator drop.
public enum WTHTTP1ResponseWriter {
    public static func write(
        head: WTHTTP1ResponseHead,
        version: WTHTTP1Version,
        keepAlive: Bool,
        mayHaveBody: Bool,
        requestMethod: WTHTTP1Method,
        contentLength: Int?,
        body: ByteBuffer?,
        trustFraming: Bool = false,
        into out: inout ByteBuffer
    ) -> Bool {
        guard
            WTHTTP1Validation.isValidReasonPhrase(
                head.reasonBytes
            )
        else {
            return false
        }

        for header in head.headers {
            guard
                WTHTTP1Validation.isValidHeaderName(
                    header.name
                ),
                WTHTTP1Validation.isValidHeaderValue(
                    header.value
                )
            else {
                return false
            }
        }

        // CONNECT responses carry no body and no framing headers;
        // HEAD responses suppress only the body bytes. Both mirror
        // the NIO encoder's method-queue behavior.
        let suppressBody =
            requestMethod == .head
            || requestMethod == .connect
        let stripFraming =
            !mayHaveBody
            || requestMethod == .connect

        var headers = head.headers
        var chunkedBody = false

        // Trusted framing mirrors the stock writer's normalized
        // path: the caller guarantees one exact Content-Length and
        // no Transfer-Encoding, so the repair scan is skipped. The
        // bodyless/CONNECT strip still runs (stock repairs those
        // regardless), and a nil length falls back to repair.
        let skipRepair = trustFraming && contentLength != nil

        if stripFraming {
            // Note: stock writeBodylessStatus keeps Content-Length
            // for 304 at the runtime level, but the NIO encoder
            // strips it downstream (proven by the
            // 304-strips-cl-keeps-etag differential case), so the
            // wire behavior is a full framing strip either way.
            headers.removeAll(where: {
                isFramingHeader($0.name)
            })
        } else if skipRepair {
            // Headers pass through untouched.
        } else if let contentLength {
            headers.removeAll(where: {
                isFramingHeader($0.name)
            })
            headers.append((
                name: WTHTTP1ResponseTokens.contentLength,
                value: Array(String(contentLength).utf8)
            ))
        } else if version == .http11 {
            headers.removeAll(where: {
                isFramingHeader($0.name)
            })
            headers.append((
                name: WTHTTP1ResponseTokens.transferEncoding,
                value: WTHTTP1ResponseTokens.chunked
            ))
            chunkedBody = true
        }

        // Connection behavior mirrors the stock runtime writer (NIO
        // itself never touches Connection).
        if !keepAlive {
            headers.removeAll(where: {
                isConnectionHeader($0.name)
            })
            headers.append((
                name: WTHTTP1ResponseTokens.connection,
                value: WTHTTP1ResponseTokens.close
            ))
        } else if version == .http10 {
            headers.removeAll(where: {
                isConnectionHeader($0.name)
            })
            headers.append((
                name: WTHTTP1ResponseTokens.connection,
                value: WTHTTP1ResponseTokens.keepAlive
            ))
        }

        writeStatusLine(
            statusCode: head.statusCode,
            reasonBytes: head.reasonBytes,
            version: version,
            into: &out
        )

        for header in headers {
            out.writeBytes(header.name)
            out.writeBytes([58, 32])
            out.writeBytes(header.value)
            out.writeBytes([13, 10])
        }

        out.writeBytes([13, 10])

        // Bodyless statuses and CONNECT responses never emit body
        // bytes, mirroring the stock runtime (which skips the write)
        // and the NIO encoder (which throws on such writes).
        guard !suppressBody, !stripFraming else {
            return true
        }

        guard var body, body.readableBytes > 0 else {
            if chunkedBody {
                out.writeBytes([48, 13, 10, 13, 10])
            }

            return true
        }

        if chunkedBody {
            out.writeString(
                String(body.readableBytes, radix: 16)
            )
            out.writeBytes([13, 10])
            out.writeBuffer(&body)
            out.writeBytes([13, 10, 48, 13, 10, 13, 10])
            return true
        }

        out.writeBuffer(&body)
        return true
    }

    /// Stock-shaped `100 Continue` interim response bytes.
    public static func writeContinue(
        into out: inout ByteBuffer
    ) {
        out.writeBytes(WTHTTP1ResponseTokens.continue100)
    }

    private static func writeStatusLine(
        statusCode: Int,
        reasonBytes: [UInt8],
        version: WTHTTP1Version,
        into out: inout ByteBuffer
    ) {
        switch version {
        case .http11:
            out.writeBytes([72, 84, 84, 80, 47, 49, 46, 49, 32])

        case .http10:
            out.writeBytes([72, 84, 84, 80, 47, 49, 46, 48, 32])
        }

        // No zero-padding, mirroring NIO's integer interpolation.
        out.writeString(String(statusCode))
        out.writeBytes([32])
        out.writeBytes(reasonBytes)
        out.writeBytes([13, 10])
    }

    private static func isFramingHeader(
        _ name: [UInt8]
    ) -> Bool {
        foldedEqual(
            name,
            WTHTTP1ResponseTokens.contentLength
        )
            || foldedEqual(
                name,
                WTHTTP1ResponseTokens.transferEncoding
            )
    }

    private static func isConnectionHeader(
        _ name: [UInt8]
    ) -> Bool {
        foldedEqual(
            name,
            WTHTTP1ResponseTokens.connection
        )
    }

    private static func foldedEqual(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        for index in lhs.indices {
            var byte = lhs[index]
            if byte >= 65 && byte <= 90 {
                byte += 32
            }

            guard byte == rhs[index] else {
                return false
            }
        }

        return true
    }
}

private enum WTHTTP1ResponseTokens {
    static let contentLength: [UInt8] = [
        99, 111, 110, 116, 101, 110, 116, 45, 108, 101, 110,
        103, 116, 104,
    ]
    static let transferEncoding: [UInt8] = [
        116, 114, 97, 110, 115, 102, 101, 114, 45, 101, 110,
        99, 111, 100, 105, 110, 103,
    ]
    static let connection: [UInt8] = [
        99, 111, 110, 110, 101, 99, 116, 105, 111, 110,
    ]
    static let close: [UInt8] = [99, 108, 111, 115, 101]
    static let keepAlive: [UInt8] = [
        107, 101, 101, 112, 45, 97, 108, 105, 118, 101,
    ]
    static let chunked: [UInt8] = [
        99, 104, 117, 110, 107, 101, 100,
    ]
    static let continue100: [UInt8] = [
        72, 84, 84, 80, 47, 49, 46, 49, 32, 49, 48, 48, 32,
        67, 111, 110, 116, 105, 110, 117, 101, 13, 10, 13, 10,
    ]
}

/// Setup-sealed response: validated once, written per request with no
/// validation, framing scan, or copy. Covers GET-like requests; HEAD
/// requests write `headBytes` only, and CONNECT requests must use the
/// general path (their framing differs).
public struct WTHTTP1SealedResponse: Sendable {
    public var headBytes: ByteBuffer
    public var bodyBytes: ByteBuffer

    public init(
        headBytes: ByteBuffer,
        bodyBytes: ByteBuffer
    ) {
        self.headBytes = headBytes
        self.bodyBytes = bodyBytes
    }
}

public enum WTHTTP1ResponseSealer {
    /// Validates and serializes once. Returns nil when any byte is
    /// invalid so setup can fail loudly instead of serving garbage.
    public static func seal(
        head: WTHTTP1ResponseHead,
        version: WTHTTP1Version,
        keepAlive: Bool,
        mayHaveBody: Bool,
        contentLength: Int,
        body: ByteBuffer?,
        trustFraming: Bool = false,
        allocator: ByteBufferAllocator = ByteBufferAllocator()
    ) -> WTHTTP1SealedResponse? {
        var headBytes = allocator.buffer(capacity: 256)
        guard
            WTHTTP1ResponseWriter.write(
                head: head,
                version: version,
                keepAlive: keepAlive,
                mayHaveBody: mayHaveBody,
                requestMethod: .get,
                contentLength: contentLength,
                body: nil,
                trustFraming: trustFraming,
                into: &headBytes
            )
        else {
            return nil
        }

        var bodyBytes = allocator.buffer(capacity: 0)
        if mayHaveBody, var body, body.readableBytes > 0 {
            bodyBytes.writeBuffer(&body)
        }

        return WTHTTP1SealedResponse(
            headBytes: headBytes,
            bodyBytes: bodyBytes
        )
    }
}
