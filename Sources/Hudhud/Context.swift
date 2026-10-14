import NIOCore

public struct Context: @unchecked Sendable {
    public let eventLoop: EventLoop
    public let remoteAddress: SocketAddress?

    internal let streamingRegistration:
        StreamingRegistration?

    init(
        eventLoop: EventLoop,
        remoteAddress: SocketAddress? = nil,
        streamingRegistration:
            StreamingRegistration? = nil
    ) {
        self.eventLoop = eventLoop
        self.remoteAddress = remoteAddress
        self.streamingRegistration =
            streamingRegistration
    }
}
