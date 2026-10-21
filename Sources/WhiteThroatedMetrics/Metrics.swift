import Dispatch
import NIOConcurrencyHelpers
import WhiteThroated

public struct HTTPMetricKey:
    Sendable,
    Hashable
{
    public let method: String
    public let route: String
    public let statusClass: Int

    public init(
        method: String,
        route: String,
        statusClass: Int
    ) {
        self.method = method
        self.route = route
        self.statusClass = statusClass
    }
}

public struct HTTPMetricValue:
    Sendable,
    Equatable
{
    public let requests: UInt64
    public let totalDurationNanoseconds: UInt64
    public let knownResponseBytes: UInt64
    public let responsesWithUnknownLength: UInt64
    public let durationBuckets: [UInt64]

    public init(
        requests: UInt64,
        totalDurationNanoseconds: UInt64,
        knownResponseBytes: UInt64,
        responsesWithUnknownLength: UInt64,
        durationBuckets: [UInt64]
    ) {
        self.requests = requests
        self.totalDurationNanoseconds =
            totalDurationNanoseconds
        self.knownResponseBytes =
            knownResponseBytes
        self.responsesWithUnknownLength =
            responsesWithUnknownLength
        self.durationBuckets = durationBuckets
    }
}

public struct HTTPMetricsSnapshot: Sendable {
    public let values:
        [HTTPMetricKey: HTTPMetricValue]
    public let durationUpperBoundsNanoseconds:
        [UInt64]

    public init(
        values:
            [HTTPMetricKey: HTTPMetricValue],
        durationUpperBoundsNanoseconds:
            [UInt64]
    ) {
        self.values = values
        self.durationUpperBoundsNanoseconds =
            durationUpperBoundsNanoseconds
    }
}

public struct HTTPMetricsConfiguration: Sendable {
    public typealias RouteClassifier =
        @Sendable (Request) -> String?
    public typealias Clock =
        @Sendable () -> UInt64

    public let allowedRoutes: Set<String>
    public let unknownRouteLabel: String
    public let durationUpperBoundsNanoseconds:
        [UInt64]
    public let routeClassifier: RouteClassifier

    internal let clock: Clock

    public init(
        allowedRoutes: Set<String>,
        unknownRouteLabel: String = "__other__",
        durationUpperBoundsNanoseconds:
            [UInt64] = [
                100_000,
                500_000,
                1_000_000,
                5_000_000,
                10_000_000,
                50_000_000,
                100_000_000,
                1_000_000_000,
            ],
        clock: @escaping Clock = {
            DispatchTime.now().uptimeNanoseconds
        },
        routeClassifier:
            @escaping RouteClassifier
    ) {
        precondition(
            !unknownRouteLabel.isEmpty,
            "Metrics unknown route label must not be empty"
        )
        precondition(
            !allowedRoutes.contains(
                unknownRouteLabel
            ),
            "Metrics unknown route label must not duplicate an allowed route"
        )

        var previous: UInt64?

        for bound in
            durationUpperBoundsNanoseconds
        {
            if let previous {
                precondition(
                    bound > previous,
                    "Metrics duration bounds must be strictly increasing"
                )
            }
            previous = bound
        }

        self.allowedRoutes = allowedRoutes
        self.unknownRouteLabel =
            unknownRouteLabel
        self.durationUpperBoundsNanoseconds =
            durationUpperBoundsNanoseconds
        self.routeClassifier = routeClassifier
        self.clock = clock
    }
}

public final class HTTPMetrics:
    @unchecked Sendable
{
    private struct MutableValue: Sendable {
        var requests: UInt64
        var totalDurationNanoseconds: UInt64
        var knownResponseBytes: UInt64
        var responsesWithUnknownLength: UInt64
        var durationBuckets: [UInt64]
    }

    public let configuration:
        HTTPMetricsConfiguration

    private let storage =
        NIOLockedValueBox(
            [HTTPMetricKey: MutableValue]()
        )

    public init(
        configuration:
            HTTPMetricsConfiguration
    ) {
        self.configuration = configuration
    }

    public func middleware() -> FastMiddleware {
        { request, _, next in
            let route =
                self.classifyRoute(request)
            let method =
                Self.methodName(
                    request.method
                )
            let start =
                self.configuration.clock()

            return self.observe(
                next(request),
                method: method,
                route: route,
                start: start
            )
        }
    }

    public func snapshot()
        -> HTTPMetricsSnapshot
    {
        storage.withLockedValue {
            values in

            var snapshot:
                [HTTPMetricKey: HTTPMetricValue] =
                    [:]
            snapshot.reserveCapacity(
                values.count
            )

            for (key, value) in values {
                snapshot[key] =
                    HTTPMetricValue(
                        requests:
                            value.requests,
                        totalDurationNanoseconds:
                            value.totalDurationNanoseconds,
                        knownResponseBytes:
                            value.knownResponseBytes,
                        responsesWithUnknownLength:
                            value.responsesWithUnknownLength,
                        durationBuckets:
                            value.durationBuckets
                    )
            }

            return HTTPMetricsSnapshot(
                values: snapshot,
                durationUpperBoundsNanoseconds:
                    configuration
                        .durationUpperBoundsNanoseconds
            )
        }
    }

    private func classifyRoute(
        _ request: Request
    ) -> String {
        guard
            let candidate =
                configuration
                    .routeClassifier(request),
            configuration
                .allowedRoutes
                .contains(candidate)
        else {
            return configuration
                .unknownRouteLabel
        }

        return candidate
    }

    private func observe(
        _ result: MiddlewareResult,
        method: String,
        route: String,
        start: UInt64
    ) -> MiddlewareResult {
        switch result {
        case .response(let response):
            record(
                method: method,
                route: route,
                statusCode:
                    Int(response.status.code),
                contentLength:
                    Self.contentLength(
                        response.headers
                    ),
                start: start
            )
            return .response(response)

        case .prepared(let prepared):
            record(
                method: method,
                route: route,
                statusCode:
                    Int(prepared.status.code),
                contentLength:
                    prepared.contentLength,
                start: start
            )
            return .prepared(prepared)

        case .future(let future):
            return .future(
                future.map { response in
                    self.record(
                        method: method,
                        route: route,
                        statusCode:
                            Int(
                                response
                                    .status
                                    .code
                            ),
                        contentLength:
                            Self.contentLength(
                                response.headers
                            ),
                        start: start
                    )
                    return response
                }
            )
        }
    }

    private func record(
        method: String,
        route: String,
        statusCode: Int,
        contentLength: Int?,
        start: UInt64
    ) {
        let end = configuration.clock()
        let duration =
            end >= start
            ? end - start
            : 0
        let key = HTTPMetricKey(
            method: method,
            route: route,
            statusClass:
                max(0, statusCode / 100)
        )
        let bounds =
            configuration
                .durationUpperBoundsNanoseconds

        storage.withLockedValue {
            values in

            var value =
                values[key]
                ?? MutableValue(
                    requests: 0,
                    totalDurationNanoseconds: 0,
                    knownResponseBytes: 0,
                    responsesWithUnknownLength: 0,
                    durationBuckets:
                        Array(
                            repeating: 0,
                            count:
                                bounds.count + 1
                        )
                )

            value.requests &+= 1
            value.totalDurationNanoseconds &+=
                duration

            if
                let contentLength,
                contentLength >= 0
            {
                value.knownResponseBytes &+=
                    UInt64(contentLength)
            } else {
                value
                    .responsesWithUnknownLength
                    &+= 1
            }

            var bucketIndex = bounds.count

            for (
                index,
                upperBound
            ) in bounds.enumerated() {
                if duration <= upperBound {
                    bucketIndex = index
                    break
                }
            }

            value.durationBuckets[
                bucketIndex
            ] &+= 1
            values[key] = value
        }
    }

    private static func contentLength(
        _ headers: NIOHTTP1.HTTPHeaders
    ) -> Int? {
        guard
            let value =
                headers.first(
                    name: "content-length"
                )
        else {
            return nil
        }

        return Int(value)
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
    func use(metrics: HTTPMetrics) {
        useFast(metrics.middleware())
    }
}
