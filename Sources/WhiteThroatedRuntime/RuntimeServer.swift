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
                channel.setOption(
                    ChannelOptions.socketOption(
                        .tcp_nodelay
                    ),
                    value: 1
                )
                .flatMapError { _ in
                    channel.eventLoop
                        .makeSucceededVoidFuture()
                }
                .flatMap {
                    channel.pipeline
                        .configureHTTPServerPipeline(
                            withPipeliningAssistance:
                                true,
                            withErrorHandling: true
                        )
                }
                .flatMap {
                    channel.pipeline.addHandler(
                        RuntimeConnectionHandler(
                            dispatcher: self.dispatcher,
                            configuration: self
                                .configuration
                        )
                    )
                }
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

    public func stop() throws {
        if let channel = serverChannel {
            try channel.close().wait()
            serverChannel = nil
        }

        try group.syncShutdownGracefully()
    }
}
