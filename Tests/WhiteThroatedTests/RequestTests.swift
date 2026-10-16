import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class RequestTests: XCTestCase {
    func testMethodMapsLazilyFromNIO() {
        let request = Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .PATCH,
                uri: "/"
            ),
            body: ByteBufferAllocator().buffer(capacity: 0)
        )

        XCTAssertEqual(
            request.method,
            .patch
        )
    }

    func testCustomMethodMapsLazilyFromNIO() {
        let request = Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .RAW(value: "PROPFIND"),
                uri: "/"
            ),
            body: ByteBufferAllocator().buffer(capacity: 0)
        )

        XCTAssertEqual(
            request.method,
            .other("PROPFIND")
        )
    }

    func testTargetedQueryLookup() {
        let request = makeRequest(
            path: "/search?q=whitethroated&page=2"
        )

        XCTAssertEqual(
            request.query("q"),
            "whitethroated"
        )
        XCTAssertEqual(
            request.query("page"),
            "2"
        )
        XCTAssertNil(
            request.query("missing")
        )
    }

    func testTargetedQueryLookupDecodesPercentAndPlus() {
        let request = makeRequest(
            path: "/search?q=hello+world&tag=swift%20server"
        )

        XCTAssertEqual(
            request.query("q"),
            "hello world"
        )
        XCTAssertEqual(
            request.query("tag"),
            "swift server"
        )
    }

    func testTargetedQueryLookupDecodesKey() {
        let request = makeRequest(
            path: "/search?hello%20world=value"
        )

        XCTAssertEqual(
            request.query("hello world"),
            "value"
        )
    }

    func testPathExcludesQueryString() {
        let request = makeRequest(
            path: "/search?q=whitethroated&limit=10"
        )

        XCTAssertEqual(request.path, "/search")
    }

    func testPathWithoutQueryReturnsOriginalURI() {
        let request = makeRequest(path: "/health")

        XCTAssertEqual(request.path, "/health")
    }

    func testQueryStringIsLazyPublicView() {
        let request = makeRequest(
            path: "/search?q=whitethroated&limit=10"
        )

        XCTAssertEqual(
            request.queryString,
            "q=whitethroated&limit=10"
        )
    }

    func testQueryReturnsDecodedValue() {
        let request = makeRequest(
            path: "/search?q=hello+world&next=%2Fhome"
        )

        XCTAssertEqual(
            request.query("q"),
            "hello world"
        )
        XCTAssertEqual(
            request.query("next"),
            "/home"
        )
    }

    func testQueryMatchesPercentEncodedKey() {
        let request = makeRequest(
            path: "/search?na%6De=whitethroated"
        )

        XCTAssertEqual(
            request.query("name"),
            "whitethroated"
        )
    }

    func testQueryParametersMaterializesValuesOnDemand() {
        let request = makeRequest(
            path: "/search?q=hello+world&limit=10"
        )

        XCTAssertEqual(
            request.queryParameters,
            [
                "q": "hello world",
                "limit": "10"
            ]
        )
    }

    func testRouteParameterIsDecodedOnAccess() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/users/42?expand=true"),
                on: loop
            )
            .wait()

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "42")
    }

    func testRouteParameterPercentDecoding() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/files/:path") { request in
            .text(request.parameter("path") ?? "")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/files/a%2Fb"),
                on: loop
            )
            .wait()

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "a/b")
    }

    func testParametersPropertyMaterializesAllValues() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/teams/:team/users/:user") { request in
            let parameters = request.parameters
            let team = parameters["team"] ?? ""
            let user = parameters["user"] ?? ""

            return .text("\(team):\(user)")
        }

        let response = try app
            .respond(
                to: makeRequest(
                    path: "/teams/core/users/42"
                ),
                on: loop
            )
            .wait()

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "core:42")
    }

    func testQueryStartsImmediatelyAfterParameter() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/users/abc?x=1"),
                on: loop
            )
            .wait()

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "abc")
    }

    private func makeRequest(path: String) -> Request {
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: path
        )

        return Request(
            head: head,
            body: ByteBufferAllocator().buffer(capacity: 0)
        )
    }
}
