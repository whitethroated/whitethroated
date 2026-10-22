import NIOCore

/// Low-level server knobs owned by the runtime.
///
/// `ServerConfiguration` in WhiteThroated maps onto this type; the
/// runtime never sees framework configuration directly.
public typealias RuntimeAcceptedChannelInitializer =
    @Sendable (Channel) -> EventLoopFuture<Void>

public struct RuntimeServerConfiguration: Sendable {
    public var eventLoopThreads: Int?
    public var backlog: Int32
    public var maxRequestBodyBytes: Int

    /// Prefer the Tier 1 HTTP/1 handler. Applications with request-streaming
    /// routes automatically use the stock NIOHTTP1 pipeline. Set false to
    /// use the stock pipeline for every application.
    public var useTier1HTTP1: Bool
    public var acceptedChannelInitializer:
        RuntimeAcceptedChannelInitializer?

    public init(
        eventLoopThreads: Int? = nil,
        backlog: Int32 = 256,
        maxRequestBodyBytes: Int = 1_048_576,
        useTier1HTTP1: Bool = true,
        acceptedChannelInitializer:
            RuntimeAcceptedChannelInitializer? = nil
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
        self.acceptedChannelInitializer =
            acceptedChannelInitializer
    }
}
