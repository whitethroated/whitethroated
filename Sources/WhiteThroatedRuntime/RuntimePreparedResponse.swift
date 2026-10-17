import NIOCore
import NIOHTTP1

/// Immutable, shareable prepared response storage owned by the runtime.
///
/// Holds the normalized response head plus an optional pre-encoded
/// body buffer. Safe to share across connections and event loops:
/// all members are immutable after initialization.
public final class RuntimePreparedResponse: @unchecked Sendable {
    public let status: HTTPResponseStatus
    public let headers: HTTPHeaders
    public let http11Head: HTTPResponseHead
    public let bodyBuffer: ByteBuffer?

    public init(
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        bodyBuffer: ByteBuffer?
    ) {
        var http11Head = HTTPResponseHead(
            version: .http1_1,
            status: status,
            headers: headers
        )

        if !status.mayHaveResponseBody {
            http11Head.headers.remove(
                name: "transfer-encoding"
            )

            if status != .notModified {
                http11Head.headers.remove(
                    name: "content-length"
                )
            }
        }

        self.status = status
        self.headers = headers
        self.http11Head = http11Head

        if
            status.mayHaveResponseBody,
            let bodyBuffer,
            bodyBuffer.readableBytes > 0
        {
            self.bodyBuffer = bodyBuffer
        } else {
            self.bodyBuffer = nil
        }
    }

    /// Framework-neutral response view for the general writer path.
    public var response: RuntimeResponse {
        RuntimeResponse(
            status: status,
            headers: headers,
            body: bodyBuffer.map(
                RuntimeResponseBody.buffer
            ) ?? .empty,
            contentLengthIsNormalized: true
        )
    }
}
