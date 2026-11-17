import NIOCore
import NIOHTTP1

/// Response data handed from framework dispatch to the runtime writer.
///
/// Plain data: status, headers, and a body in exactly one
/// writer-ready representation. `contentLengthIsNormalized` tells the
/// writer the headers already carry a correct `content-length` (or
/// none is required) so no header scan is needed on the hot path.
/// `canonicalHead`/`canonicalBodyLength` carry an optional prebuilt
/// HTTP/1.1 head for short immutable text bodies.
public struct RuntimeResponse: @unchecked Sendable {
    public var status: HTTPResponseStatus
    public var headers: HTTPHeaders
    public var body: RuntimeResponseBody
    public var contentLengthIsNormalized: Bool
    public var canonicalHead: HTTPResponseHead?
    public var canonicalBodyLength: Int?

    public init(
        status: HTTPResponseStatus,
        headers: HTTPHeaders = HTTPHeaders(),
        body: RuntimeResponseBody = .empty,
        contentLengthIsNormalized: Bool = false,
        canonicalHead: HTTPResponseHead? = nil,
        canonicalBodyLength: Int? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contentLengthIsNormalized =
            contentLengthIsNormalized
        self.canonicalHead = canonicalHead
        self.canonicalBodyLength = canonicalBodyLength
    }
}

public enum RuntimeResponseBody: @unchecked Sendable {
    case empty
    case text(String)
    case bytes([UInt8])
    case buffer(ByteBuffer)
    case fileRegion(FileRegion)
    case stream(RuntimeResponseStream)
}

/// Runtime-owned response stream: the producer receives a runtime
/// stream writer bound to the connection event loop.
public struct RuntimeResponseStream: @unchecked Sendable {
    package enum Producer: @unchecked Sendable {
        case asynchronous(
            @Sendable (RuntimeStreamWriter)
                -> EventLoopFuture<Void>
        )
        case synchronous(
            @Sendable (RuntimeStreamWriter) throws
                -> Void
        )
    }

    package var producer: Producer
    public var expectedContentLength: Int?
    public var onError:
        (@Sendable (Error) -> Void)?

    public init(
        produce:
            @escaping @Sendable (RuntimeStreamWriter)
                -> EventLoopFuture<Void>,
        expectedContentLength: Int? = nil,
        onError:
            (@Sendable (Error) -> Void)? = nil
    ) {
        self.producer = .asynchronous(produce)
        self.expectedContentLength = expectedContentLength
        self.onError = onError
    }

    package init(
        produceSynchronously:
            @escaping @Sendable (RuntimeStreamWriter) throws
                -> Void,
        expectedContentLength: Int? = nil,
        onError:
            (@Sendable (Error) -> Void)? = nil
    ) {
        self.producer = .synchronous(
            produceSynchronously
        )
        self.expectedContentLength = expectedContentLength
        self.onError = onError
    }
}
