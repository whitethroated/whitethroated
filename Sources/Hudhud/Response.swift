import Foundation
import NIOCore
import NIOHTTP1

public struct Response: Sendable {
    public enum Body: Sendable {
        case empty
        case text(String)
        case bytes([UInt8])
        case buffer(ByteBuffer)
    }

    public var status: HTTPResponseStatus
    public var headers: HTTPHeaders
    public var body: Body

    public init(
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Body = .empty
    ) {
        self.status = status
        self.headers = headers
        self.body = body
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

        return Response(
            status: status,
            headers: headers,
            body: .bytes(value)
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

        return Response(
            status: status,
            headers: headers,
            body: .buffer(value)
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

        return Response(
            status: status,
            headers: headers,
            body: .text(value)
        )
    }
}
