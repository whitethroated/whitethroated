import NIOCore
import WhiteThroatedRuntime

public struct Context: @unchecked Sendable {
    public let eventLoop: EventLoop
    public let remoteAddress: SocketAddress?

    internal let streamingRegistration:
        RuntimeStreamRegistration?

    init(
        eventLoop: EventLoop,
        remoteAddress: SocketAddress? = nil,
        streamingRegistration:
            RuntimeStreamRegistration? = nil
    ) {
        self.eventLoop = eventLoop
        self.remoteAddress = remoteAddress
        self.streamingRegistration =
            streamingRegistration
    }
}
