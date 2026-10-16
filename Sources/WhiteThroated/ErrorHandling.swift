import NIOCore

public typealias SyncErrorHandler = @Sendable (
    Error,
    Context
) -> Response

public typealias ErrorHandler = @Sendable (
    Error,
    Context
) -> EventLoopFuture<Response>

public typealias AsyncErrorHandler = @Sendable (
    Error,
    Context
) async throws -> Response

internal enum ErrorHandlerEntry {
    case synchronous(SyncErrorHandler)
    case asynchronous(ErrorHandler)
    case concurrent(AsyncErrorHandler)
}

internal enum ErrorResponderResult {
    case immediate(Response)
    case future(EventLoopFuture<Response>)
}
