import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import WhiteThroated
@testable import WhiteThroatedLifecycle
@testable import WhiteThroatedLogging
@testable import WhiteThroatedMetrics
@testable import WhiteThroatedTracing

final class ObservabilityLifecycleTests:
    XCTestCase
{
    private final class EventBox<T>:
        @unchecked Sendable
    {
        var values: [T] = []

        func append(_ value: T) {
            values.append(value)
        }
    }

    private final class ClockBox:
        @unchecked Sendable
    {
        var now: UInt64

        init(_ now: UInt64 = 0) {
            self.now = now
        }
    }

    private final class CounterBox:
        @unchecked Sendable
    {
        var value = 0
    }

    func testStructuredLoggerPreservesPreparedResponse() throws {
        let events =
            EventBox<HTTPRequestLogEvent>()
        let clock = ClockBox(100)
        let logger =
            StructuredRequestLogger(
                requestIDPolicy:
                    RequestIDPolicy(
                        generator: {
                            "generated-id"
                        }
                    ),
                routeResolver: { _ in
                    "/users/:id"
                },
                clock: {
                    defer {
                        clock.now += 25
                    }
                    return clock.now
                },
                sink: {
                    events.append($0)
                }
            )

        var headers = HTTPHeaders()
        headers.add(
            name: "x-request-id",
            value: "incoming-id"
        )
        let request = makeRequest(
            path: "/users/42",
            headers: headers
        )

        try withEventLoop { loop in
            let result =
                logger.middleware()(
                    request,
                    Context(
                        eventLoop: loop
                    )
                ) { _ in
                    .prepared(
                        .text("ok")
                    )
                }

            guard case .prepared =
                result
            else {
                XCTFail(
                    "Logging should preserve prepared responses"
                )
                return
            }
        }

        XCTAssertEqual(
            events.values.count,
            1
        )
        XCTAssertEqual(
            events.values.first,
            HTTPRequestLogEvent(
                requestID: "incoming-id",
                method: "GET",
                route: "/users/:id",
                statusCode: 200,
                durationNanoseconds: 25,
                remoteAddress: nil
            )
        )
    }

    func testUnsafeIncomingRequestIDIsReplaced() throws {
        let events =
            EventBox<HTTPRequestLogEvent>()
        let logger =
            StructuredRequestLogger(
                requestIDPolicy:
                    RequestIDPolicy(
                        generator: {
                            "safe-generated"
                        }
                    ),
                clock: { 1 },
                sink: {
                    events.append($0)
                }
            )
        var headers = HTTPHeaders()
        headers.add(
            name: "x-request-id",
            value: "bad value"
        )

        try withEventLoop { loop in
            _ = logger.middleware()(
                makeRequest(
                    headers: headers
                ),
                Context(eventLoop: loop)
            ) { _ in
                .response(.text("ok"))
            }
        }

        XCTAssertEqual(
            events.values.first?.requestID,
            "safe-generated"
        )
    }

    func testMetricsBoundRouteCardinalityAndPreservePrepared() throws {
        let clock = ClockBox(1_000)
        let metrics = HTTPMetrics(
            configuration:
                HTTPMetricsConfiguration(
                    allowedRoutes: [
                        "/users/:id",
                    ],
                    durationUpperBoundsNanoseconds:
                        [
                            50,
                            100,
                        ],
                    clock: {
                        defer {
                            clock.now += 75
                        }
                        return clock.now
                    },
                    routeClassifier: {
                        request in

                        if request.path
                            .hasPrefix(
                                "/users/"
                            )
                        {
                            return "/users/:id"
                        }

                        return request.path
                    }
                )
        )

        try withEventLoop { loop in
            let context =
                Context(eventLoop: loop)

            let prepared =
                metrics.middleware()(
                    makeRequest(
                        path: "/users/42"
                    ),
                    context
                ) { _ in
                    .prepared(
                        .text("ok")
                    )
                }

            guard case .prepared =
                prepared
            else {
                XCTFail(
                    "Metrics should preserve prepared responses"
                )
                return
            }

            _ = metrics.middleware()(
                makeRequest(
                    path:
                        "/unbounded/user-specific-value"
                ),
                context
            ) { _ in
                .response(
                    .text(
                        "missing",
                        status: .notFound
                    )
                )
            }
        }

        let snapshot =
            metrics.snapshot()

        XCTAssertEqual(
            snapshot.values.count,
            2
        )

        let knownKey = HTTPMetricKey(
            method: "GET",
            route: "/users/:id",
            statusClass: 2
        )
        let unknownKey =
            HTTPMetricKey(
                method: "GET",
                route: "__other__",
                statusClass: 4
            )

        XCTAssertEqual(
            snapshot.values[
                knownKey
            ]?.requests,
            1
        )
        XCTAssertEqual(
            snapshot.values[
                knownKey
            ]?.knownResponseBytes,
            2
        )
        XCTAssertEqual(
            snapshot.values[
                knownKey
            ]?.durationBuckets,
            [
                0,
                1,
                0,
            ]
        )
        XCTAssertEqual(
            snapshot.values[
                unknownKey
            ]?.requests,
            1
        )

        XCTAssertFalse(
            snapshot.values.keys
                .contains {
                    $0.route.contains(
                        "user-specific-value"
                    )
                }
        )
    }

    func testMetricsClampUnknownHTTPMethods() throws {
        let metrics = HTTPMetrics(
            configuration:
                HTTPMetricsConfiguration(
                    allowedRoutes: ["/"],
                    clock: { 0 },
                    routeClassifier: {
                        _ in "/"
                    }
                )
        )

        try withEventLoop { loop in
            _ = metrics.middleware()(
                makeRequest(
                    method:
                        .RAW(
                            value:
                                "CUSTOM-USER-VALUE"
                        )
                ),
                Context(eventLoop: loop)
            ) { _ in
                .response(.text("ok"))
            }
        }

        XCTAssertEqual(
            metrics.snapshot()
                .values.keys.first?
                .method,
            "OTHER"
        )
    }

    func testTraceparentParsingRejectsMalformedAndZeroIdentifiers() {
        XCTAssertEqual(
            TraceContext.parse(
                traceparent:
                    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
            ),
            TraceContext(
                traceID:
                    "4bf92f3577b34da6a3ce929d0e0e4736",
                parentSpanID:
                    "00f067aa0ba902b7",
                traceFlags: 1
            )
        )

        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "00-00000000000000000000000000000000-00f067aa0ba902b7-01"
            )
        )
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
            )
        )
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "not-a-traceparent"
            )
        )
    }

    func testTraceparentParsesHigherVersionsPositionally() {
        // Versions above "00" keep the documented field positions;
        // content after trace-flags is unknown and must be ignored
        // without validation, per the W3C trace-context versioning
        // rules.
        XCTAssertEqual(
            TraceContext.parse(
                traceparent:
                    "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-ce929d0e"
            ),
            TraceContext(
                traceID:
                    "4bf92f3577b34da6a3ce929d0e0e4736",
                parentSpanID:
                    "00f067aa0ba902b7",
                traceFlags: 1
            )
        )

        // The unknown-field area may exist without content, as long as
        // the flags end the string or are followed by a dash.
        XCTAssertEqual(
            TraceContext.parse(
                traceparent:
                    "0a-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-03-"
            ),
            TraceContext(
                traceID:
                    "4bf92f3577b34da6a3ce929d0e0e4736",
                parentSpanID:
                    "00f067aa0ba902b7",
                traceFlags: 3
            )
        )
        XCTAssertEqual(
            TraceContext.parse(
                traceparent:
                    "0f-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"
            ),
            TraceContext(
                traceID:
                    "4bf92f3577b34da6a3ce929d0e0e4736",
                parentSpanID:
                    "00f067aa0ba902b7",
                traceFlags: 0
            )
        )

        // Flags must end the string or be followed by a dash.
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x"
            )
        )

        // Headers shorter than 55 characters are never parsed.
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "01-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01"
            )
        )

        // Unknown version fields do not relax identifier validation.
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "01-00000000000000000000000000000000-00f067aa0ba902b7-01-unknown"
            )
        )

        // Version "ff" stays forbidden.
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-x"
            )
        )

        // Version "00" keeps the exact format: no trailing fields.
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-x"
            )
        )

        // Version prefixes that are not two lowercase hex characters
        // cannot be parsed as versions.
        XCTAssertNil(
            TraceContext.parse(
                traceparent:
                    "0g-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
            )
        )
    }

    func testUnsampledTraceSkipsRouteAndIdentifierWork() throws {
        let events =
            EventBox<TraceSpanEvent>()
        let routeCalls =
            CounterBox()
        let identifierCalls =
            CounterBox()
        let tracer = ServerTracer(
            sampler: { _ in false },
            routeResolver: { _ in
                routeCalls.value += 1
                return "/"
            },
            identifiers:
                TraceIdentifierGenerator(
                    traceID: {
                        identifierCalls.value += 1
                        return String(
                            repeating: "1",
                            count: 32
                        )
                    },
                    spanID: {
                        identifierCalls.value += 1
                        return String(
                            repeating: "2",
                            count: 16
                        )
                    }
                ),
            sink: {
                events.append($0)
            }
        )

        try withEventLoop { loop in
            let result =
                tracer.middleware()(
                    makeRequest(),
                    Context(eventLoop: loop)
                ) { _ in
                    .prepared(
                        .text("ok")
                    )
                }

            guard case .prepared =
                result
            else {
                XCTFail(
                    "Unsampled tracing should preserve prepared response"
                )
                return
            }
        }

        XCTAssertEqual(
            routeCalls.value,
            0
        )
        XCTAssertEqual(
            identifierCalls.value,
            0
        )
        XCTAssertTrue(
            events.values.isEmpty
        )
    }

    func testSampledTraceUsesParentTraceAndPreservesPrepared() throws {
        let events =
            EventBox<TraceSpanEvent>()
        let clock = ClockBox(10)
        let tracer = ServerTracer(
            sampler: { _ in true },
            routeResolver: { _ in
                "/users/:id"
            },
            identifiers:
                TraceIdentifierGenerator(
                    traceID: {
                        String(
                            repeating: "a",
                            count: 32
                        )
                    },
                    spanID: {
                        String(
                            repeating: "b",
                            count: 16
                        )
                    }
                ),
            clock: {
                defer {
                    clock.now += 20
                }
                return clock.now
            },
            sink: {
                events.append($0)
            }
        )
        var headers = HTTPHeaders()
        headers.add(
            name: "traceparent",
            value:
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        )

        try withEventLoop { loop in
            let result =
                tracer.middleware()(
                    makeRequest(
                        path: "/users/42",
                        headers: headers
                    ),
                    Context(eventLoop: loop)
                ) { _ in
                    .prepared(
                        .text("ok")
                    )
                }

            guard case .prepared =
                result
            else {
                XCTFail(
                    "Tracing should preserve prepared response"
                )
                return
            }
        }

        XCTAssertEqual(
            events.values,
            [
                TraceSpanEvent(
                    traceID:
                        "4bf92f3577b34da6a3ce929d0e0e4736",
                    spanID:
                        String(
                            repeating: "b",
                            count: 16
                        ),
                    parentSpanID:
                        "00f067aa0ba902b7",
                    method: "GET",
                    route: "/users/:id",
                    statusCode: 200,
                    durationNanoseconds: 20
                ),
            ]
        )
    }

    func testLifecycleTracksFutureAndRejectsNewRequestsDuringDrain() throws {
        let controller =
            LifecycleController()

        try withEventLoop { loop in
            let promise =
                loop.makePromise(
                    of: Response.self
                )

            let result =
                controller.middleware()(
                    makeRequest(),
                    Context(eventLoop: loop)
                ) { _ in
                    .future(
                        promise.futureResult
                    )
                }

            XCTAssertEqual(
                controller
                    .snapshot()
                    .activeRequests,
                1
            )

            controller.beginDrain()

            let rejected =
                controller.middleware()(
                    makeRequest(),
                    Context(eventLoop: loop)
                ) { _ in
                    .response(
                        .text(
                            "unexpected"
                        )
                    )
                }

            guard case .response(
                let rejectedResponse
            ) = rejected
            else {
                XCTFail(
                    "Draining request should be rejected immediately"
                )
                return
            }

            XCTAssertEqual(
                rejectedResponse.status,
                .serviceUnavailable
            )
            XCTAssertEqual(
                controller
                    .readinessResponse()
                    .status,
                .serviceUnavailable
            )

            promise.succeed(
                .text("done")
            )

            guard case .future(
                let future
            ) = result
            else {
                XCTFail(
                    "Expected future result"
                )
                return
            }

            _ = try future.wait()

            XCTAssertEqual(
                controller
                    .snapshot()
                    .activeRequests,
                0
            )
        }
    }

    func testLifecycleCleanupRunsInReverseOrderAndStops() async throws {
        let order = EventBox<Int>()
        let controller =
            LifecycleController()
        let application =
            Application()

        controller.registerCleanup {
            order.append(1)
        }
        controller.registerCleanup {
            order.append(2)
        }

        try await controller.shutdown(
            application: application,
            drainTimeoutNanoseconds: 0
        )

        XCTAssertEqual(
            order.values,
            [2, 1]
        )
        XCTAssertEqual(
            controller
                .snapshot()
                .phase,
            .stopped
        )
    }

    func testShutdownRunsCleanupsAtMostOnce() async throws {
        let order = EventBox<Int>()
        let controller =
            LifecycleController()
        let application =
            Application()

        controller.registerCleanup {
            order.append(1)
        }
        controller.registerCleanup {
            order.append(2)
        }

        try await controller.shutdown(
            application: application,
            drainTimeoutNanoseconds: 0
        )

        // A second shutdown must not run the teardown cleanups
        // again (nor call `Application.shutdown` a second time):
        // shutdown is at-most-once and the second call returns
        // without further teardown work.
        try await controller.shutdown(
            application: application,
            drainTimeoutNanoseconds: 0
        )

        XCTAssertEqual(
            order.values,
            [2, 1]
        )
        XCTAssertEqual(
            controller
                .snapshot()
                .phase,
            .stopped
        )
    }

    private func makeRequest(
        method:
            NIOHTTP1.HTTPMethod = .GET,
        path: String = "/",
        headers:
            HTTPHeaders = HTTPHeaders()
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: path,
                headers: headers
            ),
            body:
                ByteBufferAllocator()
                    .buffer(capacity: 0)
        )
    }

    private func withEventLoop(
        _ body:
            (EventLoop) throws -> Void
    ) throws {
        let group =
            MultiThreadedEventLoopGroup(
                numberOfThreads: 1
            )

        defer {
            try? group
                .syncShutdownGracefully()
        }

        try body(group.next())
    }
}
