import NIOCore
import NIOHTTP1

/// Request data handed from the runtime to framework dispatch.
///
/// Created and consumed on the connection event loop. `body` is the
/// aggregated body for buffered routes, or an empty buffer for
/// bodyless dispatch and streaming starts.
public struct RuntimeRequest: @unchecked Sendable {
    public var head: HTTPRequestHead
    public var body: ByteBuffer
    public var remoteAddress: SocketAddress?

    public init(
        head: HTTPRequestHead,
        body: ByteBuffer,
        remoteAddress: SocketAddress? = nil
    ) {
        self.head = head
        self.body = body
        self.remoteAddress = remoteAddress
    }
}
