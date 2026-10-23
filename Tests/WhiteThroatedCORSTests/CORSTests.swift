import NIOCore
import NIOHTTP1
import XCTest
@testable import WhiteThroated
@testable import WhiteThroatedCORS

final class CORSTests: XCTestCase {
    func testRequestWithoutOriginPassesThrough() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .exact([
                    "https://example.com"
                ])
            )
        )

        let result = cors.respond(
            to: makeRequest(),
            next: { _ in
                .response(
                    .empty(status: .accepted)
                )
            }
        )
        let response = try unwrap(result)

        XCTAssertEqual(
            response.status,
            .accepted
        )
        XCTAssertNil(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            )
        )
    }

    func testAllowedExactOriginIsEchoed() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .exact([
                    "https://example.com"
                ]),
                exposedHeaders: [
                    "x-request-id"
                ]
            )
        )

        let result = cors.respond(
            to: makeRequest(
                headers: [
                    ("origin", "https://example.com")
                ]
            ),
            next: { _ in
                .response(
                    .empty(status: .accepted)
                )
            }
        )
        let response = try unwrap(result)

        XCTAssertEqual(
            response.status,
            .accepted
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            ),
            "https://example.com"
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-expose-headers"
            ),
            "x-request-id"
        )
        XCTAssertEqual(
            response.headers.first(
                name: "vary"
            ),
            "Origin"
        )
    }

    func testDeniedOriginRejectsByDefault() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .exact([
                    "https://allowed.example"
                ])
            )
        )

        let result = cors.respond(
            to: makeRequest(
                headers: [
                    ("origin", "https://denied.example")
                ]
            ),
            next: { _ in
                .response(
                    .empty(status: .accepted)
                )
            }
        )
        let response = try unwrap(result)

        XCTAssertEqual(
            response.status,
            .forbidden
        )
        XCTAssertNil(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            )
        )
    }

    func testDeniedOriginCanPassThrough() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .exact([
                    "https://allowed.example"
                ]),
                deniedRequestBehavior:
                    .passThrough
            )
        )

        let result = cors.respond(
            to: makeRequest(
                headers: [
                    ("origin", "https://denied.example")
                ]
            ),
            next: { _ in
                .response(
                    .empty(status: .accepted)
                )
            }
        )
        let response = try unwrap(result)

        XCTAssertEqual(
            response.status,
            .accepted
        )
        XCTAssertNil(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            )
        )
    }

    func testWildcardWithoutCredentialsUsesAsterisk() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .any
            )
        )

        let response = try unwrap(
            cors.respond(
                to: makeRequest(
                    headers: [
                        (
                            "origin",
                            "https://example.com"
                        )
                    ]
                ),
                next: { _ in
                    .response(.noContent())
                }
            )
        )

        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            ),
            "*"
        )
        XCTAssertNil(
            response.headers.first(
                name:
                    "access-control-allow-credentials"
            )
        )
        XCTAssertNil(
            response.headers.first(
                name: "vary"
            )
        )
    }

    func testWildcardWithCredentialsEchoesOrigin() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .any,
                allowCredentials: true
            )
        )

        let response = try unwrap(
            cors.respond(
                to: makeRequest(
                    headers: [
                        (
                            "origin",
                            "https://example.com"
                        )
                    ]
                ),
                next: { _ in
                    .response(.noContent())
                }
            )
        )

        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            ),
            "https://example.com"
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-credentials"
            ),
            "true"
        )
        XCTAssertEqual(
            response.headers.first(
                name: "vary"
            ),
            "Origin"
        )
    }

    func testWildcardWithCredentialsDeniesOpaqueNullOrigin() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .any,
                allowCredentials: true
            )
        )

        // "null" is the browser's opaque-origin marker for
        // sandboxed frames and similar contexts. With credentials
        // allowed, echoing it would bless credentialed requests
        // from opaque origins, so the middleware must deny the
        // request instead of returning
        // `access-control-allow-origin: null`.
        for method in [NIOHTTP1.HTTPMethod.GET, .OPTIONS] {
            let response = try unwrap(cors.respond(
                to: makeRequest(
                    method: method,
                    headers: [
                        ("origin", "null"),
                        ("access-control-request-method", "GET"),
                    ]
                ),
                next: { _ in .response(.empty(status: .accepted)) }
            ))
            XCTAssertEqual(response.status, .forbidden)
            XCTAssertNil(response.headers.first(name: "access-control-allow-origin"))
            XCTAssertNil(response.headers.first(name: "access-control-allow-credentials"))
        }
    }

    func testOpaqueOriginDenialPreservesPassThroughPolicy() throws {
        let cors = CORS(configuration: .init(
            allowedOrigins: .any,
            allowCredentials: true,
            deniedRequestBehavior: .passThrough
        ))
        let response = try unwrap(cors.respond(
            to: makeRequest(headers: [("origin", "null")]),
            next: { _ in .response(.empty(status: .accepted)) }
        ))
        XCTAssertEqual(response.status, .accepted)
        XCTAssertNil(response.headers.first(name: "access-control-allow-origin"))
        XCTAssertNil(response.headers.first(name: "access-control-allow-credentials"))
    }

    func testOpaqueOriginRemainsAvailableThroughExplicitPolicy() throws {
        for policy in [CORSOriginPolicy.exact(["null"]), .custom({ $0 == "null" })] {
            let cors = CORS(configuration: .init(
                allowedOrigins: policy,
                allowCredentials: true
            ))
            let response = try unwrap(cors.respond(
                to: makeRequest(headers: [("origin", "null")]),
                next: { _ in .response(.noContent()) }
            ))
            XCTAssertEqual(response.status, .noContent)
            XCTAssertEqual(
                response.headers.first(name: "access-control-allow-origin"),
                "null"
            )
        }
    }

    func testAllowedPreflightShortCircuits() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .exact([
                    "https://example.com"
                ]),
                allowedMethods: [
                    .get,
                    .post,
                ],
                allowedHeaders: [
                    "content-type",
                    "x-api-key",
                ],
                allowCredentials: true,
                maxAge: 600
            )
        )

        let response = try unwrap(
            cors.respond(
                to: makeRequest(
                    method: .OPTIONS,
                    headers: [
                        (
                            "origin",
                            "https://example.com"
                        ),
                        (
                            "access-control-request-method",
                            "POST"
                        ),
                        (
                            "access-control-request-headers",
                            "Content-Type, X-Api-Key"
                        ),
                    ]
                ),
                next: { _ in
                    .response(
                        .empty(status: .accepted)
                    )
                }
            )
        )

        XCTAssertEqual(
            response.status,
            .noContent
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            ),
            "https://example.com"
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-credentials"
            ),
            "true"
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-methods"
            ),
            "GET, POST"
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-headers"
            ),
            "content-type, x-api-key"
        )
        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-max-age"
            ),
            "600"
        )
    }

    func testPreflightRejectsDisallowedMethod() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .any,
                allowedMethods: [.get]
            )
        )

        let response = try unwrap(
            cors.respond(
                to: makeRequest(
                    method: .OPTIONS,
                    headers: [
                        (
                            "origin",
                            "https://example.com"
                        ),
                        (
                            "access-control-request-method",
                            "DELETE"
                        ),
                    ]
                ),
                next: { _ in
                    .response(
                        .empty(status: .accepted)
                    )
                }
            )
        )

        XCTAssertEqual(
            response.status,
            .forbidden
        )
    }

    func testPreflightRejectsDisallowedHeader() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .any,
                allowedMethods: [.post],
                allowedHeaders: [
                    "content-type"
                ]
            )
        )

        let response = try unwrap(
            cors.respond(
                to: makeRequest(
                    method: .OPTIONS,
                    headers: [
                        (
                            "origin",
                            "https://example.com"
                        ),
                        (
                            "access-control-request-method",
                            "POST"
                        ),
                        (
                            "access-control-request-headers",
                            "authorization"
                        ),
                    ]
                ),
                next: { _ in
                    .response(
                        .empty(status: .accepted)
                    )
                }
            )
        )

        XCTAssertEqual(
            response.status,
            .forbidden
        )
    }

    func testCustomOriginResolver() throws {
        let cors = CORS(
            configuration: .init(
                allowedOrigins: .custom {
                    $0.hasSuffix(
                        ".example.com"
                    )
                }
            )
        )

        let response = try unwrap(
            cors.respond(
                to: makeRequest(
                    headers: [
                        (
                            "origin",
                            "https://api.example.com"
                        )
                    ]
                ),
                next: { _ in
                    .response(.noContent())
                }
            )
        )

        XCTAssertEqual(
            response.headers.first(
                name:
                    "access-control-allow-origin"
            ),
            "https://api.example.com"
        )
    }

    private func makeRequest(
        method: NIOHTTP1.HTTPMethod = .GET,
        headers: HTTPHeaders = HTTPHeaders()
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: "/resource",
                headers: headers
            ),
            body:
                ByteBufferAllocator()
                    .buffer(capacity: 0)
        )
    }

    private func makeRequest(
        method: NIOHTTP1.HTTPMethod = .GET,
        headers: [
            (String, String)
        ]
    ) -> Request {
        makeRequest(
            method: method,
            headers: HTTPHeaders(headers)
        )
    }

    private func unwrap(
        _ result: MiddlewareResult
    ) throws -> Response {
        switch result {
        case .response(let response):
            return response

        case .prepared(let prepared):
            return prepared.response

        case .future:
            XCTFail(
                "Expected synchronous middleware result"
            )
            throw UnexpectedResult()
        }
    }

    private struct UnexpectedResult: Error {}
}
