/// Low-level server knobs owned by the runtime.
///
/// `ServerConfiguration` in WhiteThroated maps onto this type; the
/// runtime never sees framework configuration directly.
public struct RuntimeServerConfiguration: Sendable {
    public var eventLoopThreads: Int?
    public var backlog: Int32
    public var maxRequestBodyBytes: Int

    /// Experimental Tier 1 HTTP/1 path: installs the single
    /// `WTHTTP1ConnectionHandler` instead of the NIOHTTP1 pipeline.
    /// Benchmark-gated experiment; default stays stock.
    public var useTier1HTTP1: Bool

    public init(
        eventLoopThreads: Int? = nil,
        backlog: Int32 = 256,
        maxRequestBodyBytes: Int = 1_048_576,
        useTier1HTTP1: Bool = false
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
        self.useTier1HTTP1 = useTier1HTTP1
    }
}
