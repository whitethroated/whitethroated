import BenchmarkHTTP1Experiment
import Foundation
import NIOCore
import NIOPosix

let environment =
    ProcessInfo.processInfo.environment

let host =
    environment[
        "WHITETHROATED_HOST"
    ] ?? "127.0.0.1"

let port =
    Int(
        environment[
            "WHITETHROATED_PORT"
        ] ?? "3000"
    ) ?? 3000

let eventLoopThreads =
    Int(
        environment[
            "WHITETHROATED_THREADS"
        ] ?? ""
    ) ?? System.coreCount

let group =
    MultiThreadedEventLoopGroup(
        numberOfThreads:
            eventLoopThreads
    )

let bootstrap =
    ServerBootstrap(group: group)
        .serverChannelOption(
            ChannelOptions.backlog,
            value: 256
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
                channel.pipeline.addHandler(
                    CustomHTTP1BenchmarkHandler(
                        allocator:
                            channel.allocator
                    )
                )
            }
        }

do {
    let channel =
        try bootstrap
            .bind(
                host: host,
                port: port
            )
            .wait()

    try channel.closeFuture.wait()
    try group.syncShutdownGracefully()
} catch {
    try? group.syncShutdownGracefully()
    throw error
}

