import Dispatch
import Foundation
import WhiteThroated

public struct RequestIDPolicy: Sendable {
    public let headerName: String
    public let acceptIncoming: Bool
    public let maxIncomingBytes: Int
    public let generator: @Sendable () -> String

    public init(
        headerName: String = "x-request-id",
        acceptIncoming: Bool = true,
        maxIncomingBytes: Int = 128,
        generator: @escaping @Sendable () -> String = {
            UUID().uuidString
        }
    ) {
        precondition(
            !headerName.isEmpty,
            "Request ID header name must not be empty"
        )
        precondition(
            maxIncomingBytes > 0,
            "Request ID maxIncomingBytes must be greater than zero"
        )

        self.headerName = headerName
        self.acceptIncoming = acceptIncoming
        self.maxIncomingBytes = maxIncomingBytes
        self.generator = generator
    }

    func resolve(_ request: Request) -> String {
        if
            acceptIncoming,
            let incoming = request.header(headerName),
            Self.isSafeIncoming(
                incoming,
                maxBytes: maxIncomingBytes
            )
        {
            return incoming
        }

        return generator()
    }

    private static func isSafeIncoming(
        _ value: String,
        maxBytes: Int
    ) -> Bool {
        let bytes = value.utf8

        guard
            !bytes.isEmpty,
            bytes.count <= maxBytes
        else {
            return false
        }

        for byte in bytes {
            if byte < 0x21 || byte > 0x7e {
                return false
            }
        }

        return true
    }
}

public struct HTTPRequestLogEvent: Sendable, Equatable {
    public let requestID: String
    public let method: String
    public let route: String?
    public let statusCode: Int
    public let durationNanoseconds: UInt64
    public let remoteAddress: String?

    public init(
        requestID: String,
        method: String,
        route: String?,
        statusCode: Int,
        durationNanoseconds: UInt64,
        remoteAddress: String?
    ) {
        self.requestID = requestID
        self.method = method
        self.route = route
        self.statusCode = statusCode
        self.durationNanoseconds = durationNanoseconds
        self.remoteAddress = remoteAddress
    }
}

public struct StructuredRequestLogger: Sendable {
    public typealias Sink =
        @Sendable (HTTPRequestLogEvent) -> Void
    public typealias RouteResolver =
        @Sendable (Request) -> String?
    public typealias Clock =
        @Sendable () -> UInt64

    public let requestIDPolicy: RequestIDPolicy
    public let routeResolver: RouteResolver?
    public let sink: Sink

    private let clock: Clock

    public init(
        requestIDPolicy: RequestIDPolicy =
            RequestIDPolicy(),
        routeResolver: RouteResolver? = nil,
        clock: @escaping Clock = {
            DispatchTime.now().uptimeNanoseconds
        },
        sink: @escaping Sink
    ) {
        self.requestIDPolicy = requestIDPolicy
        self.routeResolver = routeResolver
        self.clock = clock
        self.sink = sink
    }

    public func middleware() -> FastMiddleware {
        { request, context, next in
            let requestID =
                self.requestIDPolicy
                    .resolve(request)
            let route =
                self.routeResolver?(request)
            let start = self.clock()

            return self.observe(
                next(request),
                request: request,
                requestID: requestID,
                route: route,
                remoteAddress:
                    context.remoteAddress
                        .map {
                            String(describing: $0)
                        },
                start: start
            )
        }
    }

    private func observe(
        _ result: MiddlewareResult,
        request: Request,
        requestID: String,
        route: String?,
        remoteAddress: String?,
        start: UInt64
    ) -> MiddlewareResult {
        switch result {
        case .response(let response):
            emit(
                request: request,
                requestID: requestID,
                route: route,
                statusCode:
                    Int(response.status.code),
                remoteAddress: remoteAddress,
                start: start
            )
            return .response(response)

        case .prepared(let prepared):
            emit(
                request: request,
                requestID: requestID,
                route: route,
                statusCode:
                    Int(prepared.status.code),
                remoteAddress: remoteAddress,
                start: start
            )
            return .prepared(prepared)

        case .future(let future):
            return .future(
                future.map { response in
                    self.emit(
                        request: request,
                        requestID: requestID,
                        route: route,
                        statusCode:
                            Int(response.status.code),
                        remoteAddress:
                            remoteAddress,
                        start: start
                    )
                    return response
                }
            )
        }
    }

    private func emit(
        request: Request,
        requestID: String,
        route: String?,
        statusCode: Int,
        remoteAddress: String?,
        start: UInt64
    ) {
        let end = clock()
        let duration =
            end >= start
            ? end - start
            : 0

        sink(
            HTTPRequestLogEvent(
                requestID: requestID,
                method:
                    Self.methodName(
                        request.method
                    ),
                route: route,
                statusCode: statusCode,
                durationNanoseconds:
                    duration,
                remoteAddress:
                    remoteAddress
            )
        )
    }

    private static func methodName(
        _ method: HTTPMethod
    ) -> String {
        switch method {
        case .get: return "GET"
        case .post: return "POST"
        case .put: return "PUT"
        case .patch: return "PATCH"
        case .delete: return "DELETE"
        case .head: return "HEAD"
        case .options: return "OPTIONS"
        case .connect: return "CONNECT"
        case .trace: return "TRACE"
        case .other: return "OTHER"
        }
    }
}

public extension Application {
    func use(
        structuredLogger:
            StructuredRequestLogger
    ) {
        useFast(
            structuredLogger.middleware()
        )
    }
}
