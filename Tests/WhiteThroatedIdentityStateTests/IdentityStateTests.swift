import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import WhiteThroated
@testable import WhiteThroatedAuth
@testable import WhiteThroatedAuthRateLimit
@testable import WhiteThroatedCSRF
@testable import WhiteThroatedRateLimit
@testable import WhiteThroatedSessions

final class IdentityStateTests:
    XCTestCase
{
    private final class ClockBox:
        @unchecked Sendable
    {
        var now: UInt64

        init(_ now: UInt64) {
            self.now = now
        }
    }

    private let secretA =
        Array(
            repeating: UInt8(0x11),
            count: 32
        )
    private let secretB =
        Array(
            repeating: UInt8(0x22),
            count: 32
        )

    func testAuthenticatedRouteReturns401403AndPrincipal() async throws {
        let auth = Authenticator.bearer {
            token,
            _ in

            guard token == "valid" else {
                return nil
            }

            return AuthPrincipal(
                id: "user-1",
                roles: ["admin"]
            )
        }
        let app = Application()

        app.get(
            "/admin",
            authenticatedBy: auth,
            authorization: .role(
                "admin"
            )
        ) {
            _,
            principal in

            .text(principal.id)
        }

        try await withEventLoop {
            loop in

            let missing =
                try await app.respond(
                    to: makeRequest(),
                    on: loop
                ).get()

            XCTAssertEqual(
                missing.status,
                .unauthorized
            )
            XCTAssertEqual(
                missing.headers.first(
                    name:
                        "www-authenticate"
                ),
                "Bearer"
            )

            var invalidHeaders =
                HTTPHeaders()
            invalidHeaders.add(
                name: "authorization",
                value: "Bearer invalid"
            )

            let invalid =
                try await app.respond(
                    to: makeRequest(
                        headers:
                            invalidHeaders
                    ),
                    on: loop
                ).get()

            XCTAssertEqual(
                invalid.status,
                .unauthorized
            )

            var validHeaders =
                HTTPHeaders()
            validHeaders.add(
                name: "authorization",
                value: "Bearer valid"
            )

            let valid =
                try await app.respond(
                    to: makeRequest(
                        headers:
                            validHeaders
                    ),
                    on: loop
                ).get()

            XCTAssertEqual(
                valid.status,
                .ok
            )
            XCTAssertEqual(
                bodyText(valid),
                "user-1"
            )
        }
    }

    func testAuthorizationPolicySeparates403FromAuthentication() async throws {
        let auth =
            Authenticator.apiKey {
                key,
                _ in

                key == "known"
                    ? AuthPrincipal(
                        id: "u",
                        roles: ["user"]
                    )
                    : nil
            }
        let app = Application()

        app.get(
            "/owner",
            authenticatedBy: auth,
            authorization:
                .role("owner")
        ) { _, _ in
            .text("hidden")
        }

        var headers = HTTPHeaders()
        headers.add(
            name: "x-api-key",
            value: "known"
        )

        try await withEventLoop {
            loop in
            let response =
                try await app.respond(
                    to: makeRequest(
                        headers: headers
                    ),
                    on: loop
                ).get()

            XCTAssertEqual(
                response.status,
                .forbidden
            )
        }
    }

    func testSessionCookieRejectsTamperAndAcceptsRotatedKey() {
        let old =
            SessionSigningKey(
                id: "old",
                secret: secretA
            )
        let next =
            SessionSigningKey(
                id: "next",
                secret: secretB
            )
        let oldCodec =
            SessionCookieCodec(
                keys: [old]
            )
        let encoded =
            oldCodec.encode(
                sessionID: "session-1"
            )
        let rotatedCodec =
            SessionCookieCodec(
                keys: [
                    next,
                    old,
                ]
            )

        XCTAssertEqual(
            rotatedCodec.decode(
                encoded
            ),
            "session-1"
        )

        var tampered = encoded
        tampered.removeLast()
        tampered.append("0")

        XCTAssertNil(
            rotatedCodec.decode(
                tampered
            )
        )
    }

    func testMemorySessionStoreBoundsAndExpires() async throws {
        let clock = ClockBox(100)
        let store =
            MemorySessionStore(
                maxSessions: 2,
                clock: SessionClock {
                    clock.now
                }
            )

        try await withEventLoop {
            loop in

            try await store.save(
                Session(
                    id: "a",
                    createdAtSeconds: 100,
                    lastAccessAtSeconds:
                        100
                ),
                ttlSeconds: 10,
                on: loop
            ).get()
            try await store.save(
                Session(
                    id: "b",
                    createdAtSeconds: 100,
                    lastAccessAtSeconds:
                        100
                ),
                ttlSeconds: 10,
                on: loop
            ).get()

            _ = try await store.load(
                id: "b",
                on: loop
            ).get()

            try await store.save(
                Session(
                    id: "c",
                    createdAtSeconds: 100,
                    lastAccessAtSeconds:
                        100
                ),
                ttlSeconds: 10,
                on: loop
            ).get()

            XCTAssertEqual(
                store.count,
                2
            )
            XCTAssertNil(
                try await store.load(
                    id: "a",
                    on: loop
                ).get()
            )

            clock.now = 111

            XCTAssertNil(
                try await store.load(
                    id: "b",
                    on: loop
                ).get()
            )
        }
    }

    func testSessionManagerPersistsLoadsRotatesAndSetsSecureCookie() async throws {
        let clock = ClockBox(1_000)
        let store =
            MemorySessionStore(
                clock: SessionClock {
                    clock.now
                }
            )
        let codec =
            SessionCookieCodec(
                keys: [
                    SessionSigningKey(
                        id: "k1",
                        secret: secretA
                    ),
                ]
            )
        let ids =
            IDSequence([
                "one",
                "two",
            ])
        let manager =
            SessionManager(
                store: store,
                codec: codec,
                ttlSeconds: 60,
                clock: SessionClock {
                    clock.now
                },
                idGenerator: {
                    ids.next()
                }
            )

        try await withEventLoop {
            loop in

            var session =
                manager.create()
            session.values["user"] =
                "42"

            let cookie =
                try await manager.persist(
                    session,
                    on: loop
                ).get()

            var headers =
                HTTPHeaders()
            headers.add(
                name: "cookie",
                value:
                    "wt_session=\(cookie)"
            )
            let request =
                makeRequest(
                    headers: headers
                )

            let loaded =
                try await manager.load(
                    from: request,
                    on: loop
                ).get()

            XCTAssertEqual(
                loaded?.values[
                    "user"
                ],
                "42"
            )

            let rotated =
                try await manager.rotate(
                    session,
                    on: loop
                ).get()

            XCTAssertEqual(
                rotated.id,
                "two"
            )
            XCTAssertNil(
                try await store.load(
                    id: "one",
                    on: loop
                ).get()
            )

            var response =
                Response.text("ok")
            manager.setCookie(
                value:
                    codec.encode(
                        sessionID:
                            rotated.id
                    ),
                on: &response
            )

            let setCookie =
                try XCTUnwrap(
                    response.headers
                        .first(
                            name:
                                "set-cookie"
                        )
                )

            XCTAssertTrue(
                setCookie.contains(
                    "HttpOnly"
                )
            )
            XCTAssertTrue(
                setCookie.contains(
                    "Secure"
                )
            )
            XCTAssertTrue(
                setCookie.contains(
                    "SameSite=Lax"
                )
            )
        }
    }

    func testSessionAuthenticatorIsLazyAndEventLoopNative() async throws {
        let store =
            MemorySessionStore()
        let codec =
            SessionCookieCodec(
                keys: [
                    SessionSigningKey(
                        id: "k",
                        secret: secretA
                    ),
                ]
            )
        let manager =
            SessionManager(
                store: store,
                codec: codec
            )
        let authenticator =
            manager.authenticator {
                session in

                guard
                    let id =
                        session.values[
                            "user"
                        ]
                else {
                    return nil
                }

                return AuthPrincipal(
                    id: id
                )
            }

        try await withEventLoop {
            loop in

            var session =
                manager.create()
            session.values["user"] =
                "42"

            let value =
                try await manager.persist(
                    session,
                    on: loop
                ).get()

            var headers =
                HTTPHeaders()
            headers.add(
                name: "cookie",
                value:
                    "wt_session=\(value)"
            )

            let principal =
                try await authenticator
                    .authenticate(
                        makeRequest(
                            headers:
                                headers
                        ),
                        context:
                            Context(
                                eventLoop:
                                    loop
                            )
                    ).get()

            XCTAssertEqual(
                principal?.id,
                "42"
            )
        }
    }

    func testCSRFRequiresTokenAndAllowedOriginForUnsafeMethods() {
        let csrf = CSRFProtection(
            originPolicy:
                .allowed(
                    [
                        "https://app.example.com",
                    ],
                    requireOriginOrReferer:
                        true
                )
        )
        var session = Session(
            id: "s",
            createdAtSeconds: 1,
            lastAccessAtSeconds: 1
        )
        let token =
            csrf.ensureToken(
                in: &session
            )

        XCTAssertTrue(
            csrf.validate(
                request:
                    makeRequest(
                        method: .GET
                    ),
                session: session
            )
        )

        XCTAssertFalse(
            csrf.validate(
                request:
                    makeRequest(
                        method: .POST
                    ),
                session: session
            )
        )

        var headers = HTTPHeaders()
        headers.add(
            name: "origin",
            value:
                "https://app.example.com"
        )
        headers.add(
            name: "x-csrf-token",
            value: token
        )

        XCTAssertTrue(
            csrf.validate(
                request:
                    makeRequest(
                        method: .POST,
                        headers: headers
                    ),
                session: session
            )
        )

        headers.replaceOrAdd(
            name: "origin",
            value:
                "https://evil.example"
        )

        XCTAssertFalse(
            csrf.validate(
                request:
                    makeRequest(
                        method: .POST,
                        headers: headers
                    ),
                session: session
            )
        )
    }

    func testAuthRateLimitUsesDerivedPrincipalKey() {
        let auth =
            Authenticator.bearer {
                token,
                _ in

                guard
                    token == "secret-token"
                else {
                    return nil
                }

                return AuthPrincipal(
                    id: "user-42"
                )
            }
        let limiter =
            AuthRateLimit
                .fixedWindow(
                    authenticator: auth,
                    keyDeriver:
                        AuthRateLimitKeyDeriver(
                            secret: secretB
                        ),
                    configuration:
                        FixedWindowRateLimitConfiguration(
                            limit: 1,
                            windowSeconds:
                                60,
                            emitHeaders:
                                false
                        ),
                    clock:
                        RateLimitClock(
                            nowNanoseconds: {
                                1
                            }
                        )
                )
        var headers = HTTPHeaders()
        headers.add(
            name: "authorization",
            value:
                "Bearer secret-token"
        )
        let request =
            makeRequest(
                headers: headers
            )

        XCTAssertTrue(
            limiter
                .decision(
                    for: request
                )?
                .allowed == true
        )
        XCTAssertFalse(
            limiter
                .decision(
                    for: request
                )?
                .allowed == true
        )
    }

    private final class IDSequence:
        @unchecked Sendable
    {
        private var values: [String]

        init(_ values: [String]) {
            self.values =
                Array(
                    values.reversed()
                )
        }

        func next() -> String {
            values.removeLast()
        }
    }

    private func makeRequest(
        method:
            NIOHTTP1.HTTPMethod = .GET,
        path: String = "/admin",
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

    private func bodyText(
        _ response: Response
    ) -> String? {
        if case
            .text(let body) =
                response.body
        {
            return body
        }

        return nil
    }

    private func withEventLoop(
        _ body:
            (EventLoop) async throws
                -> Void
    ) async throws {
        let group =
            MultiThreadedEventLoopGroup(
                numberOfThreads: 1
            )

        defer {
            try? group
                .syncShutdownGracefully()
        }

        try await body(
            group.next()
        )
    }
}
