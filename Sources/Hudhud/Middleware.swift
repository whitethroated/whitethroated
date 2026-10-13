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

        case .prepared(let prepared):
            self = .prepared(prepared)

        case .future(let future):
            self = .future(future)
        }
    }

    internal var responderResult: ResponderResult {
        switch self {
        case .response(let response):
            return .immediate(response)

        case .prepared(let prepared):
            return .prepared(prepared)

        case .future(let future):
            return .future(future)
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
