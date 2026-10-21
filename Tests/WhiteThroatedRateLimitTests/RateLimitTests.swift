import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import WhiteThroated
@testable import WhiteThroatedRateLimit

final class RateLimitTests: XCTestCase {
    private final class ManualClock:
        @unchecked Sendable
    {
        var now: UInt64 = 0

        func advance(
            seconds: UInt64
        ) {
            now +=
                seconds * 1_000_000_000
        }
    }

    func testAllowsUntilLimitThenReturns429() {
        let clock = ManualClock()
        let limiter = makeLimiter(
            limit: 2,
            windowSeconds: 10,
            clock: clock
        )
        let request = makeRequest()

        let first = response(
            limiter.respond(
                to: request,
                next: okNext
            )
        )
        let second = response(
            limiter.respond(
                to: request,
                next: okNext
            )
        )
        let third = response(
            limiter.respond(
                to: request,
                next: okNext
            )
        )

        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(
            first.headers.first(
                name: "ratelimit-limit"
            ),
            "2"
        )
        XCTAssertEqual(
            first.headers.first(
                name:
                    "ratelimit-remaining"
            ),
            "1"
        )
        XCTAssertEqual(second.status, .ok)
        XCTAssertEqual(
            second.headers.first(
                name:
                    "ratelimit-remaining"
            ),
            "0"
        )

        XCTAssertEqual(
            third.status,
            .tooManyRequests
        )
        XCTAssertEqual(
            third.headers.first(
                name:
                    "ratelimit-remaining"
            ),
            "0"
        )
        XCTAssertEqual(
            third.headers.first(
                name: "ratelimit-reset"
            ),
            "10"
        )
        XCTAssertEqual(
            third.headers.first(
                name: "retry-after"
            ),
            "10"
        )
    }

    func testWindowResetsDeterministically() {
        let clock = ManualClock()
        let limiter = makeLimiter(
            limit: 1,
            windowSeconds: 5,
            clock: clock
        )
        let request = makeRequest()

        XCTAssertTrue(
            limiter
                .decision(for: request)!
                .allowed
        )
        XCTAssertFalse(
            limiter
                .decision(for: request)!
                .allowed
        )

        clock.advance(seconds: 5)

        let reset =
            limiter.decision(
                for: request
            )!

        XCTAssertTrue(reset.allowed)
        XCTAssertEqual(
            reset.remaining,
            0
        )
        XCTAssertEqual(
            reset.resetAfterSeconds,
            5
        )
        XCTAssertNil(
            reset.retryAfterSeconds
        )
    }

    func testRetryAfterRoundsUp() {
        let clock = ManualClock()
        let limiter = makeLimiter(
            limit: 1,
            windowSeconds: 5,
            clock: clock
        )
        let request = makeRequest()

        _ = limiter.decision(
            for: request
        )

        clock.now =
            4_000_000_001

        let limited =
            limiter.decision(
                for: request
            )!

        XCTAssertFalse(
            limited.allowed
        )
        XCTAssertEqual(
            limited.resetAfterSeconds,
            1
        )
        XCTAssertEqual(
            limited.retryAfterSeconds,
            1
        )
    }

    func testBoundedStoreEvictsLeastRecentlyTouchedKey() {
        let clock = ManualClock()
        let limiter =
            FixedWindowRateLimiter(
                configuration:
                    FixedWindowRateLimitConfiguration(
                        limit: 1,
                        windowSeconds: 60,
                        maxKeys: 2
                    ),
                clock: RateLimitClock {
                    clock.now
                },
                keyResolver: {
                    $0.header("x-key")
                }
            )

        _ = limiter.decision(
            for: makeRequest(
                key: "a"
            )
        )
        _ = limiter.decision(
            for: makeRequest(
                key: "b"
            )
        )

        // Touch b so a is the least-recently-used key.
        _ = limiter.decision(
            for: makeRequest(
                key: "b"
            )
        )

        _ = limiter.decision(
            for: makeRequest(
                key: "c"
            )
        )

        XCTAssertEqual(
            limiter.storedKeyCount,
            2
        )

        // a was evicted, so it starts a fresh window.
        let reintroduced =
            limiter.decision(
                for: makeRequest(
                    key: "a"
                )
            )!

        XCTAssertTrue(
            reintroduced.allowed
        )
        XCTAssertEqual(
            limiter.storedKeyCount,
            2
        )
    }

    func testMissingKeyRejectsByDefaultWithoutCallingNext() {
        var nextCalls = 0

        let limiter =
            FixedWindowRateLimiter(
                configuration:
                    FixedWindowRateLimitConfiguration(
                        limit: 10,
                        windowSeconds: 60
                    ),
                keyResolver: { _ in nil }
            )

        let result = limiter.respond(
            to: makeRequest()
        ) { _ in
            nextCalls += 1
            return .response(
                .text("unexpected")
            )
        }

        XCTAssertEqual(nextCalls, 0)
        XCTAssertEqual(
            response(result).status,
            .tooManyRequests
        )
        XCTAssertEqual(
            limiter.storedKeyCount,
            0
        )
    }

    func testMissingKeyCanExplicitlyPassThrough() {
        var nextCalls = 0

        let limiter =
            FixedWindowRateLimiter(
                configuration:
                    FixedWindowRateLimitConfiguration(
                        limit: 10,
                        windowSeconds: 60,
                        keyFailureBehavior:
                            .passThrough
                    ),
                keyResolver: { _ in nil }
            )

        let result = limiter.respond(
            to: makeRequest()
        ) { _ in
            nextCalls += 1
            return .response(.text("ok"))
        }

        XCTAssertEqual(nextCalls, 1)
        XCTAssertEqual(
            response(result).status,
            .ok
        )
        XCTAssertEqual(
            limiter.storedKeyCount,
            0
        )
    }

    func testOversizedKeyDoesNotEnterStore() {
        let limiter =
            FixedWindowRateLimiter(
                configuration:
                    FixedWindowRateLimitConfiguration(
                        limit: 10,
                        windowSeconds: 60,
                        maxKeyBytes: 4
                    ),
                keyResolver: {
                    $0.header("x-key")
                }
            )

        let result = limiter.respond(
            to: makeRequest(
                key: "12345"
            ),
            next: okNext
        )

        XCTAssertEqual(
            response(result).status,
            .tooManyRequests
        )
        XCTAssertEqual(
            limiter.storedKeyCount,
            0
        )
    }

    func testDisablingLimitHeadersPreservesPreparedResult() {
        let limiter =
            FixedWindowRateLimiter(
                configuration:
                    FixedWindowRateLimitConfiguration(
                        limit: 10,
                        windowSeconds: 60,
                        emitHeaders: false
                    ),
                keyResolver: { _ in
                    "stable-key"
                }
            )
        let prepared =
            PreparedResponse.text("ok")

        let result = limiter.respond(
            to: makeRequest()
        ) { _ in
            .prepared(prepared)
        }

        guard case .prepared =
            result
        else {
            XCTFail(
                "Prepared response should remain prepared when headers are disabled"
            )
            return
        }
    }

    func testEnabledHeadersDecoratePreparedResponse() {
        let limiter =
            FixedWindowRateLimiter(
                configuration:
                    FixedWindowRateLimitConfiguration(
                        limit: 10,
                        windowSeconds: 60
                    ),
                keyResolver: { _ in
                    "stable-key"
                }
            )
        let prepared =
            PreparedResponse.text("ok")

        let result = limiter.respond(
            to: makeRequest()
        ) { _ in
            .prepared(prepared)
        }

        guard case .response(let response) =
            result
        else {
            XCTFail(
                "Per-request rate-limit headers require a mutable response"
            )
            return
        }

        XCTAssertEqual(
            response.headers.first(
                name:
                    "ratelimit-remaining"
            ),
            "9"
        )
    }

    func testApplicationMiddlewareIntegration() async throws {
        let clock = ManualClock()
        let limiter =
            FixedWindowRateLimiter(
                configuration:
                    FixedWindowRateLimitConfiguration(
                        limit: 1,
                        windowSeconds: 60
                    ),
                clock: RateLimitClock {
                    clock.now
                },
                keyResolver: {
                    $0.header("x-api-key")
                }
            )
        let app = Application()

        app.use(
            rateLimiter: limiter
        )
        app.get(
            "/",
            response:
                PreparedResponse.text("ok")
        )

        var headers = HTTPHeaders()
        headers.add(
            name: "x-api-key",
            value: "client-1"
        )

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let first = try await app
                    .respond(
                        to: makeRequest(
                            headers: headers
                        ),
                        on: loop
                    )
                    .get()
                let second = try await app
                    .respond(
                        to: makeRequest(
                            headers: headers
                        ),
                        on: loop
                    )
                    .get()

                XCTAssertEqual(
                    first.status,
                    .ok
                )
                XCTAssertEqual(
                    second.status,
                    .tooManyRequests
                )
            }
    }

    private func makeLimiter(
        limit: Int,
        windowSeconds: Int,
        clock: ManualClock
    ) -> FixedWindowRateLimiter {
        FixedWindowRateLimiter(
            configuration:
                FixedWindowRateLimitConfiguration(
                    limit: limit,
                    windowSeconds:
                        windowSeconds
                ),
            clock: RateLimitClock {
                clock.now
            },
            keyResolver: { _ in
                "client"
            }
        )
    }

    private func makeRequest(
        key: String? = nil,
        headers:
            HTTPHeaders = HTTPHeaders()
    ) -> Request {
        var headers = headers

        if let key {
            headers.replaceOrAdd(
                name: "x-key",
                value: key
            )
        }

        return Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/",
                headers: headers
            ),
            body:
                ByteBufferAllocator()
                    .buffer(capacity: 0)
        )
    }

    private var okNext: FastNext {
        { _ in
            .response(
                .text("ok")
            )
        }
    }

    private func response(
        _ result: MiddlewareResult
    ) -> Response {
        switch result {
        case .response(let response):
            return response

        case .prepared(let prepared):
            return prepared.response

        case .future:
            XCTFail(
                "Unexpected future result"
            )
            return .internalServerError()
        }
    }
}
