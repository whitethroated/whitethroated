import NIOCore

public struct Context: @unchecked Sendable {
    public let eventLoop: EventLoop

    internal let streamingRegistration:
        StreamingRegistration?

    init(
        eventLoop: EventLoop,
        streamingRegistration:
            StreamingRegistration? = nil
    ) {
        self.eventLoop = eventLoop
        self.streamingRegistration =
            streamingRegistration
    }
}
