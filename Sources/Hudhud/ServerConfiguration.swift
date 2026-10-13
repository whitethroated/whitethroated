public struct ServerConfiguration: Sendable {
    public var maxRequestBodyBytes: Int
    public var backlog: Int32
    public var eventLoopThreads: Int?

    public init(
        maxRequestBodyBytes: Int = 1_048_576,
        backlog: Int32 = 256,
        eventLoopThreads: Int? = nil
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

        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.backlog = backlog
        self.eventLoopThreads = eventLoopThreads
    }
}
