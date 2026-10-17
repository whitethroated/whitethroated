import NIOCore
import NIOHTTP1
import WhiteThroatedRuntime

/// Test-compatibility shim over `RuntimeConnectionHandler`.
///
/// Preserves the pre-refactor
/// `HTTPServerHandler(application:maxRequestBodyBytes:)`
/// construction shape used across the framework EmbeddedChannel test
/// suite, forwarding every transport event to an owned runtime
/// handler. Production serving installs `RuntimeConnectionHandler`
/// directly (see `RuntimeServer`); this type exists only so the
/// existing tests keep exercising the real runtime handler without
/// churn. It performs no dispatch, caching, or writing itself.
final class HTTPServerHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let runtimeHandler:
        RuntimeConnectionHandler

    init(
        application: Application,
        maxRequestBodyBytes: Int? = nil
    ) {
        self.runtimeHandler =
            RuntimeConnectionHandler(
                dispatcher: application
                    .makeRuntimeDispatcher(),
                configuration: application
                    .makeRuntimeConfiguration(
                        maxRequestBodyBytes:
                            maxRequestBodyBytes
                    )
            )
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        runtimeHandler.channelRead(
            context: context,
            data: data
        )
    }

    func channelInactive(
        context: ChannelHandlerContext
    ) {
        runtimeHandler.channelInactive(
            context: context
        )
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        runtimeHandler.errorCaught(
            context: context,
            error: error
        )
    }
}
