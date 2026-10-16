import NIOCore
import NIOEmbedded

func activateHTTPTestChannel(
    _ channel: EmbeddedChannel
) throws {
    guard !channel.isActive else {
        return
    }

    try channel.connect(
        to: SocketAddress(
            ipAddress: "127.0.0.1",
            port: 1
        )
    ).wait()
}
