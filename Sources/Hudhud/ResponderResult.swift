import NIOCore

enum ResponderResult {
    case immediate(Response)
    case future(EventLoopFuture<Response>)

    @inline(__always)
    func asFuture(
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Response> {
        switch self {
        case .immediate(let response):
            return eventLoop.makeSucceededFuture(response)

        case .future(let future):
            return future
        }
    }
}

typealias InternalHandler = @Sendable (
    Request,
    Context
) -> ResponderResult
