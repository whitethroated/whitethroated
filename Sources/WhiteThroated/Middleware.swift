import NIOCore

public typealias Next = @Sendable (
    Request
) -> EventLoopFuture<Response>

public typealias Middleware = @Sendable (
    Request,
    Context,
    @escaping Next
) -> EventLoopFuture<Response>

public enum MiddlewareResult: @unchecked Sendable {
    case response(Response)
    case prepared(PreparedResponse)
    case future(EventLoopFuture<Response>)

    public func map(
        _ transform: @escaping @Sendable (Response) -> Response
    ) -> MiddlewareResult {
        switch self {
        case .response(let response):
            return .response(transform(response))

        case .prepared(let prepared):
            return .response(
                transform(prepared.response)
            )

        case .future(let future):
            return .future(
                future.map(transform)
            )
        }
    }

    internal init(_ result: ResponderResult) {
        switch result {
        case .immediate(let response):
            self = .response(response)

        case .prepared(let storage):
            self = .prepared(
                PreparedResponse(storage: storage)
            )

        case .streaming(let session):
            self = .future(
                session.responseFuture
            )

        case .future(let future):
            self = .future(future)
        }
    }

    internal var responderResult: ResponderResult {
        switch self {
        case .response(let response):
            return .immediate(response)

        case .prepared(let prepared):
            return .prepared(prepared.storage)

        case .future(let future):
            return .future(future)
        }
    }

    @inline(__always)
    internal func asFuture(
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Response> {
        switch self {
        case .response(let response):
            return eventLoop.makeSucceededFuture(
                response
            )

        case .prepared(let prepared):
            return eventLoop.makeSucceededFuture(
                prepared.response
            )

        case .future(let future):
            return future
        }
    }
}

public typealias FastNext = @Sendable (
    Request
) -> MiddlewareResult

public typealias FastMiddleware = @Sendable (
    Request,
    Context,
    @escaping FastNext
) -> MiddlewareResult
