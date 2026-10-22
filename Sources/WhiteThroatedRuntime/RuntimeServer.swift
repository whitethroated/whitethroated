import NIOCore
import NIOPosix

/// Runtime-owned server bootstrap: event-loop group ownership, socket
/// configuration, pipeline setup, and shutdown. Semantics mirror the
/// pre-refactor `Application.listen` pipeline exactly (TCP no-delay,
/// HTTP server pipeline with pipelining assistance and error
/// handling); only the handler type changed.
public final class RuntimeServer: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let configuration: RuntimeServerConfiguration
    private let dispatcher: RuntimeDispatcher
    private var serverChannel: Channel?

    public init(
        configuration: RuntimeServerConfiguration,
        dispatcher: RuntimeDispatcher
    ) {
        self.configuration = configuration
        self.dispatcher = dispatcher
        self.group = MultiThreadedEventLoopGroup(
            numberOfThreads:
                configuration.eventLoopThreads
                ?? System.coreCount
        )
    }

    @discardableResult
    public func start(
        host: String = "127.0.0.1",
        port: Int = 3000
    ) throws -> Channel {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.backlog,
                value: configuration.backlog
            )
            .serverChannelOption(
                ChannelOptions.socketOption(
                    .so_reuseaddr
                ),
                value: 1
            )
            .childChannelOption(
                ChannelOptions.socketOption(
                    .so_reuseaddr
                ),
                value: 1
            )
            .childChannelInitializer { channel in
                Self.configureAcceptedChannel(
                    channel: channel,
                    dispatcher: self.dispatcher,
                    configuration: self.configuration
                )
            }

        do {
            let channel = try bootstrap
                .bind(host: host, port: port)
                .wait()

            serverChannel = channel
            return channel
        } catch {
            try? group.syncShutdownGracefully()
            throw error
        }
    }

    internal static func configureAcceptedChannel(
        channel: Channel,
        dispatcher: RuntimeDispatcher,
        configuration: RuntimeServerConfiguration
    ) -> EventLoopFuture<Void> {
        channel.setOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .flatMap {
                if let initializer =
                    configuration
                        .acceptedChannelInitializer
                {
                    return initializer(channel)
                }

                return channel.eventLoop
                    .makeSucceededVoidFuture()
            }
            .flatMap {
                Self.configureHTTPPipeline(
                    channel: channel,
                    dispatcher: dispatcher,
                    configuration: configuration
                )
            }
    }

    /// Application configuration is frozen before child channels are
    /// initialized. Select the transport once for the entire connection;
    /// request streaming needs the stock decoder and backpressure pump.
    internal static func configureHTTPPipeline(
        channel: Channel,
        dispatcher: RuntimeDispatcher,
        configuration: RuntimeServerConfiguration
    ) -> EventLoopFuture<Void> {
        if configuration.useTier1HTTP1,
            !dispatcher.hasStreamingRoutes,
            configuration.httpServerUpgrade == nil
        {
            return channel.pipeline.addHandler(
                WTHTTP1ConnectionHandler(
                    dispatcher: dispatcher,
                    configuration: configuration
                )
            )
        }

        let runtimeHandler =
            RuntimeConnectionHandler(
                dispatcher: dispatcher,
                configuration: configuration
            )

        let upgrade:
            NIOHTTPServerUpgradeSendableConfiguration?

        if let configuredUpgrade =
            configuration.httpServerUpgrade
        {
            upgrade = (
                upgraders:
                    configuredUpgrade.upgraders,
                completionHandler: {
                    context in

                    context.pipeline
                        .syncOperations
                        .removeHandler(
                            runtimeHandler,
                            promise: nil
                        )

                    configuredUpgrade
                        .completionHandler(
                            context
                        )
                }
            )
        } else {
            upgrade = nil
        }

        return channel.pipeline.configureHTTPServerPipeline(
            withPipeliningAssistance: true,
            withServerUpgrade: upgrade,
            withErrorHandling: true
        ).flatMap {
            channel.pipeline.addHandler(
                runtimeHandler
            )
        }
    }

    public func stop() throws {
        if let channel = serverChannel {
            try channel.close().wait()
            serverChannel = nil
        }

        try group.syncShutdownGracefully()
    }
}
