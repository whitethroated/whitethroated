import Foundation
import NIOCore
import NIOHTTP1

public struct Response: Sendable {
    private static let cachedStringHeaderLimit = 64

    private static let noCanonicalHTTP11Head:
        UInt8 = .max

    private static let textHTTP11HeadCache =
        makeKnownLengthHTTP11HeadCache(
            contentType: "text/plain; charset=utf-8"
        )

    private static let htmlHTTP11HeadCache =
        makeKnownLengthHTTP11HeadCache(
            contentType: "text/html; charset=utf-8"
        )

    private static let jsonHTTP11HeadCache =
        makeKnownLengthHTTP11HeadCache(
            contentType: "application/json; charset=utf-8"
        )

    public enum Body: Sendable {
        case empty
        case text(String)
        case bytes([UInt8])
        case buffer(ByteBuffer)
        case fileRegion(FileRegion)
        case stream(ResponseStream)
    }

    public var status: HTTPResponseStatus {
        didSet {
            canonicalHTTP11HeadIndex =
                Self.noCanonicalHTTP11Head
        }
    }

    public var headers: HTTPHeaders {
        didSet {
            contentLengthIsNormalized = false
            canonicalHTTP11HeadIndex =
                Self.noCanonicalHTTP11Head
        }
    }

    public var body: Body {
        didSet {
            contentLengthIsNormalized = false
            canonicalHTTP11HeadIndex =
                Self.noCanonicalHTTP11Head
        }
    }

    internal var contentLengthIsNormalized: Bool
    internal var canonicalHTTP11HeadIndex: UInt8

    public init(
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Body = .empty
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentLengthIsNormalized = false
        self.canonicalHTTP11HeadIndex =
            Self.noCanonicalHTTP11Head
    }

    private init(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        body: Body,
        normalizedContentLength: Bool,
        canonicalHTTP11HeadIndex: UInt8 =
            Self.noCanonicalHTTP11Head
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentLengthIsNormalized =
            normalizedContentLength
        self.canonicalHTTP11HeadIndex =
            canonicalHTTP11HeadIndex
    }

    public static func text(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        response(
            value,
            contentType: "text/plain; charset=utf-8",
            cachedHeads: textHTTP11HeadCache,
            cacheBase: 0,
            status: status
        )
    }

    public static func html(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        response(
            value,
            contentType: "text/html; charset=utf-8",
            cachedHeads: htmlHTTP11HeadCache,
            cacheBase: 65,
            status: status
        )
    }

    public static func json(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        response(
            value,
            contentType: "application/json; charset=utf-8",
            cachedHeads: jsonHTTP11HeadCache,
            cacheBase: 130,
            status: status
        )
    }

    public static func json<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder(),
        status: HTTPResponseStatus = .ok
    ) throws -> Response {
        let data = try encoder.encode(value)
        var encodedBuffer = ByteBufferAllocator().buffer(
            capacity: data.count
        )
        encodedBuffer.writeBytes(data)

        return Response.buffer(
            encodedBuffer,
            contentType: "application/json; charset=utf-8",
            status: status
        )
    }

    public static func bytes(
        _ value: [UInt8],
        contentType: String? = nil,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        var headers = HTTPHeaders()

        if let contentType {
            headers.add(
                name: "content-type",
                value: contentType
            )
        }

        headers.add(
            name: "content-length",
            value: String(value.count)
        )

        return Response(
            status: status,
            headers: headers,
            body: .bytes(value),
            normalizedContentLength: true
        )
    }

    public static func fileRegion(
        _ value: FileRegion,
        contentType: String? = nil,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        var headers = HTTPHeaders()

        if let contentType {
            headers.add(
                name: "content-type",
                value: contentType
            )
        }

        headers.add(
            name: "content-length",
            value: String(value.readableBytes)
        )

        return Response(
            status: status,
            headers: headers,
            body: .fileRegion(value),
            normalizedContentLength: true
        )
    }

    public static func sse(
        status: HTTPResponseStatus = .ok,
        onError: ResponseStream.ErrorHandler? = nil,
        produce: @escaping ResponseStream.Producer
    ) -> Response {
        var response = stream(
            contentType: "text/event-stream; charset=utf-8",
            status: status,
            onError: onError,
            produce: produce
        )
        response.headers.add(
            name: "cache-control",
            value: "no-cache"
        )

        return response
    }

    public static func stream(
        contentType: String? = nil,
        contentLength: Int? = nil,
        status: HTTPResponseStatus = .ok,
        onError: ResponseStream.ErrorHandler? = nil,
        produce: @escaping ResponseStream.Producer
    ) -> Response {
        if let contentLength {
            precondition(
                contentLength >= 0,
                "contentLength must be zero or greater"
            )
        }

        var headers = HTTPHeaders()

        if let contentType {
            headers.add(
                name: "content-type",
                value: contentType
            )
        }

        if let contentLength {
            headers.add(
                name: "content-length",
                value: String(contentLength)
            )
        }

        return Response(
            status: status,
            headers: headers,
            body: .stream(
                ResponseStream(
                    producer: produce,
                    errorHandler: onError,
                    expectedContentLength:
                        contentLength
                )
            ),
            normalizedContentLength:
                contentLength != nil
        )
    }

    /// Creates a response stream whose producer completes
    /// synchronously on the connection event loop.
    ///
    /// Use this variant for CPU-only or already-available chunks when
    /// the producer does not need per-write completion futures. Use
    /// `stream` for future-based backpressure or asynchronous work.
    public static func streamSync(
        contentType: String? = nil,
        contentLength: Int? = nil,
        status: HTTPResponseStatus = .ok,
        onError: ResponseStream.ErrorHandler? = nil,
        produce:
            @escaping ResponseStream.SynchronousProducer
    ) -> Response {
        if let contentLength {
            precondition(
                contentLength >= 0,
                "contentLength must be zero or greater"
            )
        }

        var headers = HTTPHeaders()

        if let contentType {
            headers.add(
                name: "content-type",
                value: contentType
            )
        }

        if let contentLength {
            headers.add(
                name: "content-length",
                value: String(contentLength)
            )
        }

        return Response(
            status: status,
            headers: headers,
            body: .stream(
                ResponseStream(
                    synchronousProducer: produce,
                    errorHandler: onError,
                    expectedContentLength:
                        contentLength
                )
            ),
            normalizedContentLength:
                contentLength != nil
        )
    }

    public static func buffer(
        _ value: ByteBuffer,
        contentType: String? = nil,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        var headers = HTTPHeaders()

        if let contentType {
            headers.add(
                name: "content-type",
                value: contentType
            )
        }

        headers.add(
            name: "content-length",
            value: String(value.readableBytes)
        )

        return Response(
            status: status,
            headers: headers,
            body: .buffer(value),
            normalizedContentLength: true
        )
    }

    public static func empty(
        status: HTTPResponseStatus = .ok
    ) -> Response {
        Response(status: status)
    }

    public static func redirect(
        _ location: String,
        status: HTTPResponseStatus = .seeOther
    ) -> Response {
        var headers = HTTPHeaders()
        headers.add(
            name: "location",
            value: location
        )

        return Response(
            status: status,
            headers: headers
        )
    }

    public static func noContent() -> Response {
        empty(status: .noContent)
    }

    public static func notFound() -> Response {
        text(
            "Not Found",
            status: .notFound
        )
    }

    public static func payloadTooLarge() -> Response {
        text(
            "Payload Too Large",
            status: .payloadTooLarge
        )
    }

    public static func internalServerError() -> Response {
        text(
            "Internal Server Error",
            status: .internalServerError
        )
    }

    private static func response(
        _ value: String,
        contentType: String,
        cachedHeads: [HTTPResponseHead],
        cacheBase: UInt8,
        status: HTTPResponseStatus
    ) -> Response {
        let length = value.utf8.count
        let headers: HTTPHeaders
        let canonicalIndex: UInt8

        if length <= cachedStringHeaderLimit {
            headers =
                cachedHeads[length].headers

            if status == .ok {
                canonicalIndex =
                    cacheBase
                    + UInt8(length)
            } else {
                canonicalIndex =
                    noCanonicalHTTP11Head
            }
        } else {
            headers = makeKnownLengthHeaders(
                contentType: contentType,
                length: length
            )
            canonicalIndex =
                noCanonicalHTTP11Head
        }

        return Response(
            status: status,
            headers: headers,
            body: .text(value),
            normalizedContentLength: true,
            canonicalHTTP11HeadIndex:
                canonicalIndex
        )
    }

    private static func makeKnownLengthHTTP11HeadCache(
        contentType: String
    ) -> [HTTPResponseHead] {
        (0...cachedStringHeaderLimit).map {
            HTTPResponseHead(
                version: .http1_1,
                status: .ok,
                headers: makeKnownLengthHeaders(
                    contentType: contentType,
                    length: $0
                )
            )
        }
    }

    @inline(__always)
    internal var canonicalHTTP11BodyLength: Int? {
        let index = canonicalHTTP11HeadIndex

        guard index != Self.noCanonicalHTTP11Head else {
            return nil
        }

        return Int(
            index % 65
        )
    }

    @inline(__always)
    internal var canonicalHTTP11Head:
        HTTPResponseHead?
    {
        let index = canonicalHTTP11HeadIndex

        guard index != Self.noCanonicalHTTP11Head else {
            return nil
        }

        switch index {
        case 0...64:
            return Self.textHTTP11HeadCache[
                Int(index)
            ]

        case 65...129:
            return Self.htmlHTTP11HeadCache[
                Int(index) - 65
            ]

        default:
            return Self.jsonHTTP11HeadCache[
                Int(index) - 130
            ]
        }
    }

    private static func makeKnownLengthHeaders(
        contentType: String,
        length: Int
    ) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: contentType
        )
        headers.add(
            name: "content-length",
            value: String(length)
        )
        return headers
    }
}
