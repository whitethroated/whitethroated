import Foundation
import NIOCore
import NIOHTTP1

public struct Response: Sendable {
    public enum Body: Sendable {
        case empty
        case text(String)
        case bytes([UInt8])
        case buffer(ByteBuffer)
        case fileRegion(FileRegion)
        case stream(ResponseStream)
    }

    public var status: HTTPResponseStatus

    public var headers: HTTPHeaders {
        didSet {
            contentLengthIsNormalized = false
        }
    }

    public var body: Body {
        didSet {
            contentLengthIsNormalized = false
        }
    }

    internal var contentLengthIsNormalized: Bool

    public init(
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Body = .empty
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentLengthIsNormalized = false
    }

    private init(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        body: Body,
        normalizedContentLength: Bool
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentLengthIsNormalized =
            normalizedContentLength
    }

    public static func text(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        response(
            value,
            contentType: "text/plain; charset=utf-8",
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
                    errorHandler: onError
                )
            )
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
        status: HTTPResponseStatus
    ) -> Response {
        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: contentType
        )
        headers.add(
            name: "content-length",
            value: String(value.utf8.count)
        )

        return Response(
            status: status,
            headers: headers,
            body: .text(value),
            normalizedContentLength: true
        )
    }
}
