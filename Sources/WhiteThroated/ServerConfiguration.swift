public struct ServerConfiguration: Sendable {
    public var maxRequestBodyBytes: Int
    public var backlog: Int32
    public var eventLoopThreads: Int?

    /// Prefer the Tier 1 HTTP/1 transport (enabled by default). Applications
    /// with request-streaming routes automatically use SwiftNIO's HTTP/1
    /// pipeline. Set false to select that pipeline explicitly.
    /// The historical property name is retained for source compatibility.
    public var useTier1HTTP1Experimental: Bool

    public init(
        maxRequestBodyBytes: Int = 1_048_576,
        backlog: Int32 = 256,
        eventLoopThreads: Int? = nil,
        useTier1HTTP1Experimental: Bool = true
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
        self.useTier1HTTP1Experimental =
            useTier1HTTP1Experimental
    }
}
