import Dispatch
import Foundation
import WhiteThroated

public struct TraceContext:
    Sendable,
    Equatable
{
    public let traceID: String
    public let parentSpanID: String
    public let traceFlags: UInt8

    public var sampled: Bool {
        traceFlags & 0x01 == 0x01
    }

    public init(
        traceID: String,
        parentSpanID: String,
        traceFlags: UInt8
    ) {
        precondition(
            Self.isValidHex(
                traceID,
                length: 32,
                allowAllZero: false
            ),
            "traceID must be 32 non-zero-capable hexadecimal characters"
        )
        precondition(
            Self.isValidHex(
                parentSpanID,
                length: 16,
                allowAllZero: false
            ),
            "parentSpanID must be 16 non-zero-capable hexadecimal characters"
        )

        self.traceID = traceID.lowercased()
        self.parentSpanID =
            parentSpanID.lowercased()
        self.traceFlags = traceFlags
    }

    public static func parse(
        traceparent: String
    ) -> TraceContext? {
        let bytes = Array(
            traceparent.utf8
        )

        guard
            bytes.count == 55,
            bytes[2] == 45,
            bytes[35] == 45,
            bytes[52] == 45
        else {
            return nil
        }

        let version = String(
            decoding: bytes[0..<2],
            as: UTF8.self
        )

        guard version == "00" else {
            return nil
        }

        let traceID = String(
            decoding: bytes[3..<35],
            as: UTF8.self
        )
        let parentSpanID = String(
            decoding: bytes[36..<52],
            as: UTF8.self
        )
        let flagsString = String(
            decoding: bytes[53..<55],
            as: UTF8.self
        )

        guard
            isValidHex(
                traceID,
                length: 32,
                allowAllZero: false
            ),
            isValidHex(
                parentSpanID,
                length: 16,
                allowAllZero: false
            ),
            let flags =
                UInt8(
                    flagsString,
                    radix: 16
                )
        else {
            return nil
        }

        return TraceContext(
            traceID: traceID,
            parentSpanID: parentSpanID,
            traceFlags: flags
        )
    }

    fileprivate static func isValidHex(
        _ value: String,
        length: Int,
        allowAllZero: Bool
    ) -> Bool {
        guard value.utf8.count == length else {
            return false
        }

        var hasNonZero = false

        for byte in value.utf8 {
            switch byte {
            case 48:
                break
            case 49...57,
                 65...70,
                 97...102:
                hasNonZero = true
            default:
                return false
            }
        }

        return allowAllZero || hasNonZero
    }
}

public struct TraceIdentifierGenerator:
    Sendable
{
    public let traceID:
        @Sendable () -> String
    public let spanID:
        @Sendable () -> String

    public init(
        traceID:
            @escaping @Sendable () -> String,
        spanID:
            @escaping @Sendable () -> String
    ) {
        self.traceID = traceID
        self.spanID = spanID
    }

    public static let random =
        TraceIdentifierGenerator(
            traceID: {
                UUID()
                    .uuidString
                    .replacingOccurrences(
                        of: "-",
                        with: ""
                    )
                    .lowercased()
            },
            spanID: {
                String(
                    UUID()
                        .uuidString
                        .replacingOccurrences(
                            of: "-",
                            with: ""
                        )
                        .lowercased()
                        .prefix(16)
                )
            }
        )
}

public struct TraceSpanEvent:
    Sendable,
    Equatable
{
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let method: String
    public let route: String?
    public let statusCode: Int
    public let durationNanoseconds: UInt64

    public init(
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        method: String,
        route: String?,
        statusCode: Int,
        durationNanoseconds: UInt64
    ) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.method = method
        self.route = route
        self.statusCode = statusCode
        self.durationNanoseconds =
            durationNanoseconds
    }
}

public struct ServerTracer: Sendable {
    public typealias Sampler =
        @Sendable (TraceContext?) -> Bool
    public typealias Sink =
        @Sendable (TraceSpanEvent) -> Void
    public typealias RouteResolver =
        @Sendable (Request) -> String?
    public typealias Clock =
        @Sendable () -> UInt64

    public let sampler: Sampler
    public let routeResolver: RouteResolver?
    public let identifiers:
        TraceIdentifierGenerator
    public let sink: Sink

    private let clock: Clock

    public init(
        sampler: @escaping Sampler = {
            parent in
            parent?.sampled ?? true
        },
        routeResolver: RouteResolver? = nil,
        identifiers:
            TraceIdentifierGenerator = .random,
        clock: @escaping Clock = {
            DispatchTime.now().uptimeNanoseconds
        },
        sink: @escaping Sink
    ) {
        self.sampler = sampler
        self.routeResolver = routeResolver
        self.identifiers = identifiers
        self.clock = clock
        self.sink = sink
    }

    public func middleware() -> FastMiddleware {
        { request, _, next in
            let parent =
                request
                    .header("traceparent")
                    .flatMap(
                        TraceContext.parse(
                            traceparent:
                        )
                    )

            guard self.sampler(parent) else {
                return next(request)
            }

            let traceID =
                parent?.traceID
                ?? self.validTraceID()
            let spanID =
                self.validSpanID()
            let route =
                self.routeResolver?(request)
            let start = self.clock()

            return self.observe(
                next(request),
                request: request,
                traceID: traceID,
                spanID: spanID,
                parentSpanID:
                    parent?.parentSpanID,
                route: route,
                start: start
            )
        }
    }

    private func observe(
        _ result: MiddlewareResult,
        request: Request,
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        route: String?,
        start: UInt64
    ) -> MiddlewareResult {
        switch result {
        case .response(let response):
            emit(
                request: request,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                route: route,
                statusCode:
                    Int(response.status.code),
                start: start
            )
            return .response(response)

        case .prepared(let prepared):
            emit(
                request: request,
                traceID: traceID,
                spanID: spanID,
                parentSpanID: parentSpanID,
                route: route,
                statusCode:
                    Int(prepared.status.code),
                start: start
            )
            return .prepared(prepared)

        case .future(let future):
            return .future(
                future.map { response in
                    self.emit(
                        request: request,
                        traceID: traceID,
                        spanID: spanID,
                        parentSpanID:
                            parentSpanID,
                        route: route,
                        statusCode:
                            Int(
                                response
                                    .status
                                    .code
                            ),
                        start: start
                    )
                    return response
                }
            )
        }
    }

    private func emit(
        request: Request,
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        route: String?,
        statusCode: Int,
        start: UInt64
    ) {
        let end = clock()
        let duration =
            end >= start
            ? end - start
            : 0

        sink(
            TraceSpanEvent(
                traceID: traceID,
                spanID: spanID,
                parentSpanID:
                    parentSpanID,
                method:
                    Self.methodName(
                        request.method
                    ),
                route: route,
                statusCode: statusCode,
                durationNanoseconds:
                    duration
            )
        )
    }

    private func validTraceID() -> String {
        let value = identifiers.traceID()

        precondition(
            TraceContext.isValidHex(
                value,
                length: 32,
                allowAllZero: false
            ),
            "Trace ID generator returned an invalid trace ID"
        )

        return value.lowercased()
    }

    private func validSpanID() -> String {
        let value = identifiers.spanID()

        precondition(
            TraceContext.isValidHex(
                value,
                length: 16,
                allowAllZero: false
            ),
            "Trace ID generator returned an invalid span ID"
        )

        return value.lowercased()
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
    func use(tracer: ServerTracer) {
        useFast(tracer.middleware())
    }
}
