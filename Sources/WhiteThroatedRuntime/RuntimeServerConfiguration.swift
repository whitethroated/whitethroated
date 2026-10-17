/// Low-level server knobs owned by the runtime.
///
/// `ServerConfiguration` in WhiteThroated maps onto this type; the
/// runtime never sees framework configuration directly.
public struct RuntimeServerConfiguration: Sendable {
    public var eventLoopThreads: Int?
    public var backlog: Int32
    public var maxRequestBodyBytes: Int

    public init(
        eventLoopThreads: Int? = nil,
        backlog: Int32 = 256,
        maxRequestBodyBytes: Int = 1_048_576
    ) {
        precondition(
            maxRequestBodyBytes >= 0,
            "maxRequestBodyBytes must be zero or greater"
        )
        precondition(
            backlog > 0,
            "backlog must be greater than zero"
        )

        if let eventLoopThreads {
            precondition(
                eventLoopThreads > 0,
                "eventLoopThreads must be greater than zero"
            )
        }

        self.eventLoopThreads = eventLoopThreads
        self.backlog = backlog
        self.maxRequestBodyBytes = maxRequestBodyBytes
    }
}
