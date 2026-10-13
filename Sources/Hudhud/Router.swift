import NIOCore

public typealias Handler = @Sendable (Request, Context) -> EventLoopFuture<Response>

struct Route {
    enum Segment {
        case literal(String)
        case parameter(String)
    }

    let method: HTTPMethod
    let segments: [Segment]
    let handler: Handler

    init(method: HTTPMethod, path: String, handler: @escaping Handler) {
        self.method = method
        self.segments = Route.parse(path)
        self.handler = handler
    }

    func match(method: HTTPMethod, path: String) -> [String: String]? {
        guard self.method == method else {
            return nil
        }

        let pathSegments = Route.pathSegments(path)

        guard pathSegments.count == segments.count else {
            return nil
        }

        var parameters: [String: String] = [:]
        parameters.reserveCapacity(2)

        for (routeSegment, pathSegment) in zip(segments, pathSegments) {
            switch routeSegment {
            case .literal(let literal):
                guard literal == pathSegment else {
                    return nil
                }
            case .parameter(let name):
                parameters[name] = pathSegment
            }
        }

        return parameters
    }

    private static func parse(_ path: String) -> [Segment] {
        pathSegments(path).map { segment in
            if segment.first == ":" {
                return .parameter(String(segment.dropFirst()))
            }

            return .literal(segment)
        }
    }

    private static func pathSegments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

final class Router: @unchecked Sendable {
    private var routes: [Route] = []

    func add(method: HTTPMethod, path: String, handler: @escaping Handler) {
        routes.append(Route(method: method, path: path, handler: handler))
    }

    func resolve(
        _ request: Request,
        context: Context
    ) -> EventLoopFuture<Response> {
        for route in routes {
            if let parameters = route.match(method: request.method, path: request.path) {
                var matchedRequest = request
                matchedRequest.parameters = parameters
                return route.handler(matchedRequest, context)
            }
        }

        return context.eventLoop.makeSucceededFuture(.notFound())
    }
}
