import NIOCore

/// Server-only HTTP/1 request head owned by WhiteThroated.
///
/// Zero-copy view over the retained head bytes: every accessor slices
/// `storage` by integer offsets, so routing and framing decisions never
/// materialize Strings. Decoded text is produced only when a consumer
/// explicitly asks for it (Tier 1 boundary conversion or lazy APIs).
public struct WTHTTP1RequestHead: Sendable {
    /// Retained head bytes (request line + header block, no body).
    public var storage: ByteBuffer

    public var methodRange: Range<Int>
    public var uriRange: Range<Int>
    public var version: WTHTTP1Version

    public var headerNameRanges: [Range<Int>]
    public var headerValueRanges: [Range<Int>]

    /// Body framing resolved at parse time. `.none` proves the body is
    /// empty; anything else requires the body path.
    public var framing: WTHTTP1BodyFraming

    /// Keep-alive resolved from version + Connection tokens.
    public var keepAlive: Bool

    /// First `Expect` header resolved at parse time. `.continue100`
    /// must be answered with `100 Continue` before the body is read;
    /// `.unsupported` (including any non-HTTP/1.1 expectation) must be
    /// rejected with 417, mirroring the stock runtime.
    public var expectation: WTHTTP1Expectation

    public init(
        storage: ByteBuffer,
        methodRange: Range<Int>,
        uriRange: Range<Int>,
        version: WTHTTP1Version,
        headerNameRanges: [Range<Int>] = [],
        headerValueRanges: [Range<Int>] = [],
        framing: WTHTTP1BodyFraming = .none,
        keepAlive: Bool = true,
        expectation: WTHTTP1Expectation = .none
    ) {
        self.storage = storage
        self.methodRange = methodRange
        self.uriRange = uriRange
        self.version = version
        self.headerNameRanges = headerNameRanges
        self.headerValueRanges = headerValueRanges
        self.framing = framing
        self.keepAlive = keepAlive
        self.expectation = expectation
        precondition(
            headerNameRanges.count
                == headerValueRanges.count
        )
    }

    public var headerCount: Int {
        headerNameRanges.count
    }

    public var method: WTHTTP1Method {
        WTHTTP1Method(
            matching: storageSlice(methodRange)
        )
    }

    /// Raw URI bytes without validation or decoding.
    public func uriBytes() -> [UInt8] {
        storageSlice(uriRange)
    }

    public func headerName(
        at index: Int
    ) -> [UInt8] {
        storageSlice(headerNameRanges[index])
    }

    public func headerValue(
        at index: Int
    ) -> [UInt8] {
        storageSlice(headerValueRanges[index])
    }

    /// First header value whose name matches ASCII case-insensitively.
    public func firstHeaderValue(
        named name: [UInt8]
    ) -> [UInt8]? {
        for index in 0..<headerNameRanges.count {
            if bytesCaseInsensitiveEqual(
                storageSlice(
                    headerNameRanges[index]
                ),
                name
            ) {
                return storageSlice(
                    headerValueRanges[index]
                )
            }
        }

        return nil
    }

    private func storageSlice(
        _ range: Range<Int>
    ) -> [UInt8] {
        var view = storage
        view.moveReaderIndex(
            to: range.lowerBound
        )
        view.moveWriterIndex(
            to: range.upperBound
        )
        return Array(view.readableBytesView)
    }

    private func bytesCaseInsensitiveEqual(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        for index in lhs.indices {
            var left = lhs[index]
            var right = rhs[index]

            if left >= 65 && left <= 90 {
                left += 32
            }

            if right >= 65 && right <= 90 {
                right += 32
            }

            guard left == right else {
                return false
            }
        }

        return true
    }
}

public enum WTHTTP1Version: Sendable, Hashable {
    case http10
    case http11
}

/// HTTP methods, mirroring `NIOHTTP1.HTTPMethod` 1:1 so the Tier 1
/// boundary converts without a lookup table. Case-sensitive like the
/// wire: anything else (including lowercase `get`) is `.custom` with
/// its raw bytes.
public enum WTHTTP1Method: Sendable, Hashable {
    case get
    case put
    case acl
    case head
    case post
    case copy
    case lock
    case move
    case bind
    case link
    case patch
    case trace
    case mkcol
    case merge
    case purge
    case notify
    case search
    case unlock
    case rebind
    case unbind
    case report
    case delete
    case unlink
    case connect
    case msearch
    case options
    case propfind
    case checkout
    case propatch
    case subscribe
    case mkcalendar
    case mkactivity
    case unsubscribe
    case source
    case custom([UInt8])

    init(matching bytes: [UInt8]) {
        // Frequency-ordered so common methods match in 1-7 probes.
        for candidate in Self.knownMethods {
            if candidate.bytes.count == bytes.count
                && candidate.bytes == bytes
            {
                self = candidate.method
                return
            }
        }

        self = .custom(bytes)
    }

    private static let knownMethods: [
        (method: WTHTTP1Method, bytes: [UInt8])
    ] = [
        (.get, [71, 69, 84]),
        (.post, [80, 79, 83, 84]),
        (.head, [72, 69, 65, 68]),
        (.put, [80, 85, 84]),
        (.delete, [68, 69, 76, 69, 84, 69]),
        (.patch, [80, 65, 84, 67, 72]),
        (.options, [79, 80, 84, 73, 79, 78, 83]),
        (.trace, [84, 82, 65, 67, 69]),
        (.connect, [67, 79, 78, 78, 69, 67, 84]),
        (.acl, [65, 67, 76]),
        (.copy, [67, 79, 80, 89]),
        (.lock, [76, 79, 67, 75]),
        (.move, [77, 79, 86, 69]),
        (.bind, [66, 73, 78, 68]),
        (.link, [76, 73, 78, 75]),
        (.mkcol, [77, 75, 67, 79, 76]),
        (.merge, [77, 69, 82, 71, 69]),
        (.purge, [80, 85, 82, 71, 69]),
        (.notify, [78, 79, 84, 73, 70, 89]),
        (.search, [83, 69, 65, 82, 67, 72]),
        (.unlock, [85, 78, 76, 79, 67, 75]),
        (.rebind, [82, 69, 66, 73, 78, 68]),
        (.unbind, [85, 78, 66, 73, 78, 68]),
        (.report, [82, 69, 80, 79, 82, 84]),
        (.unlink, [85, 78, 76, 73, 78, 75]),
        (.msearch, [77, 83, 69, 65, 82, 67, 72]),
        (.propfind, [80, 82, 79, 80, 70, 73, 78, 68]),
        (.checkout, [67, 72, 69, 67, 75, 79, 85, 84]),
        (.propatch, [80, 82, 79, 80, 80, 65, 84, 67, 72]),
        (.subscribe, [83, 85, 66, 83, 67, 82, 73, 66, 69]),
        (.mkcalendar, [77, 75, 67, 65, 76, 69, 78, 68,
            65, 82]),
        (.mkactivity, [77, 75, 65, 67, 84, 73, 86, 73,
            84, 89]),
        (.unsubscribe, [85, 78, 83, 85, 66, 83, 67, 82,
            73, 66, 69]),
        (.source, [83, 79, 85, 82, 67, 69]),
    ]
}

public enum WTHTTP1BodyFraming: Sendable, Hashable {
    case none
    case contentLength(Int)
    case chunked
}

public enum WTHTTP1Expectation: Sendable, Hashable {
    case none
    case continue100
    case unsupported
}

public enum WTHTTP1ParseError: Error, Sendable, Hashable {
    case badRequestLine
    case unsupportedVersion
    case badHeaderLine
    case headerNameEmpty
    case tooManyHeaders
    case headTooLarge
    case badContentLength
    case ambiguousFraming
    case unsupportedTransferEncoding
    case badChunkFraming
}
