import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class RouterTests: XCTestCase {
    func testStaticRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/health") { _ in
            .text("ok")
        }

        let request = makeRequest(path: "/health")
        let response = try app.respond(to: request, on: loop).wait()

        XCTAssertEqual(response.status, .ok)
    }

    func testPathParameter() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let request = makeRequest(path: "/users/42")
        let response = try app.respond(to: request, on: loop).wait()

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "42")
    }

    func testMissingRouteReturnsNotFound() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let request = makeRequest(path: "/missing")
        let response = try app.respond(to: request, on: loop).wait()

        XCTAssertEqual(response.status, .notFound)
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
