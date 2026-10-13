import NIOCore

enum ResponderResult {
    case immediate(Response)
    case prepared(PreparedResponse)
    case future(EventLoopFuture<Response>)

    @inline(__always)
    func asFuture(
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Response> {
        switch self {
        case .immediate(let response):
            return eventLoop.makeSucceededFuture(response)

        case .prepared(let prepared):
            return eventLoop.makeSucceededFuture(
                prepared.response
            )

        case .future(let future):
            return future
        }
    }
}

typealias InternalHandler = @Sendable (
    Request,
    Context
) -> ResponderResult
