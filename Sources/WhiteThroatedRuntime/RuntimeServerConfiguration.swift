import NIOCore
import NIOHTTP1

/// Low-level server knobs owned by the runtime.
///
/// `ServerConfiguration` in WhiteThroated maps onto this type; the
/// runtime never sees framework configuration directly.
public typealias RuntimeAcceptedChannelInitializer =
    @Sendable (Channel) -> EventLoopFuture<Void>

/// Decides whether an error fired by the pipeline's upgrade machinery
/// should be swallowed so the re-delivered request can receive an HTTP
/// response before the connection closes.
///
/// NIOHTTP1's `HTTPServerProtocolUpgrader` flow downgrades a refused
/// upgrade by firing the refusal error and then re-delivering the
/// original request downstream. Swallowing such errors lets the
/// request reach normal dispatch and produce a real HTTP status
/// instead of tearing the connection down without a response. The
/// runtime stays protocol-agnostic: the installed filter decides
/// which error types count as downgrade-able. A matched error is only
/// swallowed before a request head or active request stream. The response
/// uses `Connection: close`: NIO's decoder cannot resume after an upgrade.
public typealias RuntimeUpgradeErrorFilter =
    @Sendable (Error) -> Bool

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
    public var httpServerUpgrade:
        NIOHTTPServerUpgradeSendableConfiguration?
    public var upgradeErrorFilter:
        RuntimeUpgradeErrorFilter?

    public init(
        eventLoopThreads: Int? = nil,
        backlog: Int32 = 256,
        maxRequestBodyBytes: Int = 1_048_576,
        useTier1HTTP1: Bool = true,
        acceptedChannelInitializer:
            RuntimeAcceptedChannelInitializer? = nil,
        httpServerUpgrade:
            NIOHTTPServerUpgradeSendableConfiguration? = nil,
        upgradeErrorFilter:
            RuntimeUpgradeErrorFilter? = nil
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
        self.httpServerUpgrade =
            httpServerUpgrade
        self.upgradeErrorFilter =
            upgradeErrorFilter
    }
}
