import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import WhiteThroated
@testable import WhiteThroatedValidation

final class ValidationTests: XCTestCase {
    private struct Payload: Codable, Equatable {
        let name: String
        let count: Int
    }

    func testSchemaCollectsMissingAndInvalidFields() throws {
        var headers = HTTPHeaders()
        headers.add(
            name: "x-role",
            value: "guest"
        )
        headers.add(
            name: "cookie",
            value: "theme=dark; session=abc"
        )

        let request = makeRequest(
            path: "/items?q=ab",
            headers: headers
        )

        let schema = ValidationSchema(
            fields: [
                .query(
                    "q",
                    rules: [
                        .minLength(3),
                    ]
                ),
                .query(
                    "page",
                    required: false,
                    rules: [
                        .nonEmpty,
                    ]
                ),
                .header(
                    "x-role",
                    rules: [
                        .oneOf([
                            "admin",
                            "owner",
                        ]),
                    ]
                ),
                .cookie(
                    "session",
                    rules: [
                        .minLength(3),
                    ]
                ),
                .header("x-required"),
            ]
        )

        let result = request.validate(schema)

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(
            result.issues.map(\.code),
            [
                .tooShort,
                .notAllowed,
                .missing,
            ]
        )
        XCTAssertEqual(
            result.values[
                .query,
                "q"
            ],
            "ab"
        )
        XCTAssertEqual(
            result.values[
                .cookie,
                "session"
            ],
            "abc"
        )
        XCTAssertNil(
            result.values[
                .query,
                "page"
            ]
        )

        XCTAssertThrowsError(
            try result.get()
        ) { error in
            guard let failure =
                error as? ValidationFailure
            else {
                XCTFail(
                    "Expected ValidationFailure"
                )
                return
            }

            XCTAssertEqual(
                failure.issues,
                result.issues
            )
        }
    }

    func testQueryValidationValidatesMaterializedDuplicateValue() {
        // A duplicated query key materializes as the last occurrence;
        // validation must judge the same value handlers read from
        // `queryParameters` instead of the first raw occurrence.
        let request = makeRequest(
            path: "/?page=1&page=999"
        )
        let schema = ValidationSchema(
            fields: [
                .query(
                    "page",
                    rules: [
                        .maxLength(2),
                    ]
                ),
            ]
        )

        let result = request.validate(schema)

        XCTAssertFalse(result.isValid)

        XCTAssertEqual(
            result.issues.first?.code,
            .tooLong
        )
        XCTAssertEqual(
            result.values[
                .query,
                "page"
            ],
            "999"
        )
    }

    func testCustomRuleUsesConfiguredCodeAndMessage() {
        let request = makeRequest(
            path: "/?slug=UPPER"
        )
        let schema = ValidationSchema(
            fields: [
                .query(
                    "slug",
                    rules: [
                        .custom(
                            code: .predicateFailed,
                            message:
                                "Slug must be lowercase",
                            predicate: {
                                $0 == $0.lowercased()
                            }
                        ),
                    ]
                ),
            ]
        )

        let result = request.validate(schema)

        XCTAssertEqual(
            result.issues,
            [
                ValidationIssue(
                    location: .query,
                    field: "slug",
                    code: .predicateFailed,
                    message:
                        "Slug must be lowercase"
                ),
            ]
        )
    }

    func testSuccessfulSchemaReturnsValidatedValues() throws {
        var headers = HTTPHeaders()
        headers.add(
            name: "x-mode",
            value: "fast"
        )

        let request = makeRequest(
            path: "/?limit=10",
            headers: headers
        )
        let limit = ValidationField.query(
            "limit",
            rules: [
                .nonEmpty,
            ]
        )
        let mode = ValidationField.header(
            "x-mode",
            rules: [
                .oneOf([
                    "fast",
                    "safe",
                ]),
            ]
        )
        let schema = ValidationSchema(
            fields: [
                limit,
                mode,
            ]
        )

        let values = try request
            .validate(schema)
            .get()

        XCTAssertEqual(
            values.value(for: limit),
            "10"
        )
        XCTAssertEqual(
            values.value(for: mode),
            "fast"
        )
    }

    func testPathFieldValidatesAfterRouterResolution() async throws {
        let app = Application()
        let schema = ValidationSchema(
            fields: [
                .path(
                    "id",
                    rules: [
                        .nonEmpty,
                        .minLength(2),
                    ]
                ),
            ]
        )

        app.get("/users/:id") { request in
            let result = request.validate(
                schema
            )

            guard
                let values = try? result.get(),
                let id = values[
                    .path,
                    "id"
                ]
            else {
                return .text(
                    "invalid",
                    status: .badRequest
                )
            }

            return .text(id)
        }

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let response = try await app
                    .respond(
                        to: makeRequest(
                            path: "/users/42"
                        ),
                        on: group.next()
                    )
                    .get()

                XCTAssertEqual(
                    response.status,
                    .ok
                )

                guard case .text(let body) =
                    response.body
                else {
                    XCTFail(
                        "Expected text response"
                    )
                    return
                }

                XCTAssertEqual(body, "42")
            }
    }

    func testDecodeValidatedJSON() throws {
        let request = makeRequest(
            method: .POST,
            path: "/",
            body:
                #"{"name":"swift","count":2}"#
        )

        let decoded: Payload =
            try request.decodeValidatedJSON()

        XCTAssertEqual(
            decoded,
            Payload(
                name: "swift",
                count: 2
            )
        )
    }

    func testJSONByteLimitRejectsBeforeDecode() {
        let request = makeRequest(
            method: .POST,
            path: "/",
            body:
                #"{"name":"swift","count":2}"#
        )

        assertBodyFailure(
            request,
            limits: JSONValidationLimits(
                maxBytes: 4,
                maxDepth: 64
            ),
            code: .bodyTooLarge
        )
    }

    func testJSONDepthLimitRejectsNestedInput() {
        let request = makeRequest(
            method: .POST,
            path: "/",
            body:
                #"{"a":{"b":{"c":1}}}"#
        )

        struct Nested: Decodable {
            let a: A

            struct A: Decodable {
                let b: B
            }

            struct B: Decodable {
                let c: Int
            }
        }

        do {
            let _: Nested =
                try request.decodeValidatedJSON(
                    limits:
                        JSONValidationLimits(
                            maxBytes: 1_024,
                            maxDepth: 2
                        )
                )
            XCTFail(
                "Expected bodyTooDeep"
            )
        } catch let failure as ValidationFailure {
            XCTAssertEqual(
                failure.issues.first?.code,
                .bodyTooDeep
            )
        } catch {
            XCTFail(
                "Unexpected error: \(error)"
            )
        }
    }

    func testDepthScannerIgnoresBracketsInsideJSONString() throws {
        struct TextPayload: Decodable {
            let value: String
        }

        let request = makeRequest(
            method: .POST,
            path: "/",
            body:
                #"{"value":"[[[[{{{{"}"#
        )

        let decoded: TextPayload =
            try request.decodeValidatedJSON(
                limits:
                    JSONValidationLimits(
                        maxBytes: 1_024,
                        maxDepth: 1
                    )
            )

        XCTAssertEqual(
            decoded.value,
            "[[[[{{{{"
        )
    }

    func testMalformedJSONReturnsStructuredFailure() {
        let request = makeRequest(
            method: .POST,
            path: "/",
            body:
                #"{"name":"swift","count":}"#
        )

        assertBodyFailure(
            request,
            code: .malformedBody
        )
    }

    func testEmptyJSONBodyReturnsMissingFailure() {
        let request = makeRequest(
            method: .POST,
            path: "/"
        )

        assertBodyFailure(
            request,
            code: .missing
        )
    }

    private func assertBodyFailure(
        _ request: Request,
        limits: JSONValidationLimits =
            .default,
        code: ValidationIssueCode
    ) {
        do {
            let _: Payload =
                try request
                    .decodeValidatedJSON(
                        limits: limits
                    )
            XCTFail(
                "Expected validation failure"
            )
        } catch let failure as ValidationFailure {
            XCTAssertEqual(
                failure.issues.count,
                1
            )
            XCTAssertEqual(
                failure.issues.first?.location,
                .body
            )
            XCTAssertEqual(
                failure.issues.first?.code,
                code
            )
        } catch {
            XCTFail(
                "Unexpected error: \(error)"
            )
        }
    }

    private func makeRequest(
        method: NIOHTTP1.HTTPMethod = .GET,
        path: String,
        headers: HTTPHeaders =
            HTTPHeaders(),
        body: String? = nil
    ) -> Request {
        var buffer =
            ByteBufferAllocator()
                .buffer(
                    capacity:
                        body?.utf8.count ?? 0
                )

        if let body {
            buffer.writeString(body)
        }

        return Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: path,
                headers: headers
            ),
            body: buffer
        )
    }
}
