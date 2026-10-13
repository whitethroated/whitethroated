import NIOCore
import NIOHTTP1

public struct PreparedResponse: Sendable {
    internal let response: Response
    internal let http11Head: HTTPResponseHead
    internal let bodyBuffer: ByteBuffer?

    private init(
        response: Response,
        http11Head: HTTPResponseHead,
        bodyBuffer: ByteBuffer?
    ) {
        self.response = response
        self.http11Head = http11Head
        self.bodyBuffer = bodyBuffer
    }

    public static func text(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> PreparedResponse {
        var buffer = ByteBufferAllocator().buffer(
            capacity: value.utf8.count
        )
        buffer.writeString(value)

        return make(
            buffer: buffer,
            contentType: "text/plain; charset=utf-8",
            status: status
        )
    }

    public static func json(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> PreparedResponse {
        var buffer = ByteBufferAllocator().buffer(
            capacity: value.utf8.count
        )
        buffer.writeString(value)

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
