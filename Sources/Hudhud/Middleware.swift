import NIOCore

public typealias Next = @Sendable (Request) -> EventLoopFuture<Response>

public typealias Middleware = @Sendable (
    Request,
    Context,
    @escaping Next
) -> EventLoopFuture<Response>
