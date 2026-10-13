import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class RequestTests: XCTestCase {
    func testPathExcludesQueryString() {
        let request = makeRequest(
            path: "/search?q=hudhud&limit=10"
        )

        XCTAssertEqual(request.path, "/search")
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
