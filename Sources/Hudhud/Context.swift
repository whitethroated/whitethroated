import NIOCore

public struct Context: @unchecked Sendable {
    public let eventLoop: EventLoop

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }
}
