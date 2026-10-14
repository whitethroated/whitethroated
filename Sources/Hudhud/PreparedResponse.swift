import Foundation
import NIOCore
import NIOHTTP1

internal final class PreparedResponseStorage: Sendable {
    let response: Response
    let http11Head: HTTPResponseHead
    let bodyBuffer: ByteBuffer?

    init(
        response: Response,
        http11Head: HTTPResponseHead,
        bodyBuffer: ByteBuffer?
    ) {
        self.response = response
        self.http11Head = http11Head
        self.bodyBuffer = bodyBuffer
    }
}

public struct PreparedResponse: Sendable {
    internal let storage: PreparedResponseStorage

    internal init(
        storage: PreparedResponseStorage
    ) {
        self.storage = storage
    }

    @inline(__always)
    internal var response: Response {
        storage.response
    }

    @inline(__always)
    internal var http11Head: HTTPResponseHead {
        storage.http11Head
    }

    @inline(__always)
    internal var bodyBuffer: ByteBuffer? {
        storage.bodyBuffer
    }

    private init(
        response: Response,
        http11Head: HTTPResponseHead,
        bodyBuffer: ByteBuffer?
    ) {
        self.storage = PreparedResponseStorage(
            response: response,
            http11Head: http11Head,
            bodyBuffer: bodyBuffer
        )
    }

    public static func text(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> PreparedResponse {
        encodedString(
            value,
            contentType: "text/plain; charset=utf-8",
            status: status
        )
    }

    public static func html(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> PreparedResponse {
        encodedString(
            value,
            contentType: "text/html; charset=utf-8",
            status: status
        )
    }

    public static func json(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> PreparedResponse {
        encodedString(
            value,
            contentType: "application/json; charset=utf-8",
            status: status
        )
    }

    public static func json<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder(),
        status: HTTPResponseStatus = .ok
    ) throws -> PreparedResponse {
        let data = try encoder.encode(value)
        var buffer = ByteBufferAllocator().buffer(
            capacity: data.count
        )
        buffer.writeBytes(data)

        return make(
            buffer: buffer,
            contentType: "application/json; charset=utf-8",
            status: status
        )
    }

    public static func bytes(
        _ value: [UInt8],
        contentType: String? = nil,
        status: HTTPResponseStatus = .ok
    ) -> PreparedResponse {
        var buffer = ByteBufferAllocator().buffer(
            capacity: value.count
        )
        buffer.writeBytes(value)

        return make(
            buffer: buffer,
            contentType: contentType,
            status: status
        )
    }

    public static func buffer(
        _ value: ByteBuffer,
        contentType: String? = nil,
        status: HTTPResponseStatus = .ok
    ) -> PreparedResponse {
        make(
            buffer: value,
            contentType: contentType,
            status: status
        )
    }

    public static func redirect(
        _ location: String,
        status: HTTPResponseStatus = .seeOther
    ) -> PreparedResponse {
        var headers = HTTPHeaders()
        headers.add(
            name: "location",
            value: location
        )
        headers.add(
            name: "content-length",
            value: "0"
        )

        let response = Response(
            status: status,
            headers: headers,
            body: .empty
        )

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: status,
                headers: headers
            ),
            bodyBuffer: nil
        )
    }

    public func header(
        _ name: String,
        _ value: String
    ) -> PreparedResponse {
        var headers = response.headers
        headers.replaceOrAdd(
            name: name,
            value: value
        )

        var response = response
        response.headers = headers

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: response.status,
                headers: headers
            ),
            bodyBuffer: bodyBuffer
        )
    }

    public func etag(
        _ tag: EntityTag
    ) -> PreparedResponse {
        var response = response
        response.setETag(tag)

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: response.status,
                headers: response.headers
            ),
            bodyBuffer: bodyBuffer
        )
    }

    public func attachment(
        _ filename: String
    ) -> PreparedResponse {
        var response = response
        response.setAttachment(filename)

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: response.status,
                headers: response.headers
            ),
            bodyBuffer: bodyBuffer
        )
    }

    public func cookie(
        _ name: String,
        value: String,
        options: CookieOptions = CookieOptions()
    ) -> PreparedResponse {
        var response = response
        response.setCookie(
            name,
            value: value,
            options: options
        )

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: response.status,
                headers: response.headers
            ),
            bodyBuffer: bodyBuffer
        )
    }

    public func clearCookie(
        _ name: String,
        path: String? = nil,
        domain: String? = nil
    ) -> PreparedResponse {
        var response = response
        response.clearCookie(
            name,
            path: path,
            domain: domain
        )

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: response.status,
                headers: response.headers
            ),
            bodyBuffer: bodyBuffer
        )
    }

    internal var notModifiedStorage:
        PreparedResponseStorage
    {
        var response = response
        response.status = .notModified
        response.body = .empty

        return PreparedResponseStorage(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: .notModified,
                headers: response.headers
            ),
            bodyBuffer: nil
        )
    }

    public static func empty(
        status: HTTPResponseStatus = .noContent
    ) -> PreparedResponse {
        var headers = HTTPHeaders()
        headers.add(
            name: "content-length",
            value: "0"
        )

        let response = Response(
            status: status,
            headers: headers,
            body: .empty
        )

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: status,
                headers: headers
            ),
            bodyBuffer: nil
        )
    }

    private static func encodedString(
        _ value: String,
        contentType: String,
        status: HTTPResponseStatus
    ) -> PreparedResponse {
        var buffer = ByteBufferAllocator().buffer(
            capacity: value.utf8.count
        )
        buffer.writeString(value)

        return make(
            buffer: buffer,
            contentType: contentType,
            status: status
        )
    }

    private static func make(
        buffer: ByteBuffer,
        contentType: String?,
        status: HTTPResponseStatus
    ) -> PreparedResponse {
        var headers = HTTPHeaders()

        if let contentType {
            headers.add(
                name: "content-type",
                value: contentType
            )
        }

        headers.add(
            name: "content-length",
            value: String(buffer.readableBytes)
        )

        let response = Response(
            status: status,
            headers: headers,
            body: .buffer(buffer)
        )

        return PreparedResponse(
            response: response,
            http11Head: HTTPResponseHead(
                version: .http1_1,
                status: status,
                headers: headers
            ),
            bodyBuffer: buffer
        )
    }
}
