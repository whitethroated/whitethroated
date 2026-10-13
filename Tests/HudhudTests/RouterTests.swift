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

        let response = try app
            .respond(to: makeRequest(path: "/health"), on: loop)
            .wait()

        XCTAssertEqual(response.status, .ok)
    }

    func testRootRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/") { _ in
            .text("root")
        }

        let response = try app
            .respond(to: makeRequest(path: "/"), on: loop)
            .wait()

        XCTAssertTextBody(response, equals: "root")
    }

    func testPathParameter() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let response = try app
            .respond(to: makeRequest(path: "/users/42"), on: loop)
            .wait()

        XCTAssertTextBody(response, equals: "42")
    }

    func testMultiplePathParameters() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/teams/:team/users/:user") { request in
            let team = request.parameter("team") ?? ""
            let user = request.parameter("user") ?? ""
            return .text("\(team):\(user)")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/teams/core/users/42"),
                on: loop
            )
            .wait()

        XCTAssertTextBody(response, equals: "core:42")
    }

    func testStaticRouteWinsOverParameterRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { _ in
            .text("parameter")
        }

        app.get("/users/me") { _ in
            .text("static")
        }

        let response = try app
            .respond(to: makeRequest(path: "/users/me"), on: loop)
            .wait()

        XCTAssertTextBody(response, equals: "static")
    }

    func testRoutesAreMethodAware() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/resource") { _ in
            .text("get")
        }

        app.post("/resource") { _ in
            .text("post")
        }

        let getResponse = try app
            .respond(
                to: makeRequest(path: "/resource", method: .GET),
                on: loop
            )
            .wait()

        let postResponse = try app
            .respond(
                to: makeRequest(path: "/resource", method: .POST),
                on: loop
            )
            .wait()

        XCTAssertTextBody(getResponse, equals: "get")
        XCTAssertTextBody(postResponse, equals: "post")
    }

    func testQueryStringDoesNotAffectRouting() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/search") { _ in
            .text("matched")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/search?q=hudhud"),
                on: loop
            )
            .wait()

        XCTAssertTextBody(response, equals: "matched")
    }

    func testMissingRouteReturnsNotFound() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let response = try app
            .respond(to: makeRequest(path: "/missing"), on: loop)
            .wait()

        XCTAssertEqual(response.status, .notFound)
    }

    private func makeRequest(
        path: String,
        method: NIOHTTP1.HTTPMethod = .GET
    ) -> Request {
        let head = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: path
        )

        return Request(
            head: head,
            body: ByteBufferAllocator().buffer(capacity: 0)
        )
    }

    private func XCTAssertTextBody(
        _ response: Response,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .text(let body) = response.body else {
            return XCTFail(
                "Expected text response",
                file: file,
                line: line
            )
        }

        XCTAssertEqual(
            body,
            expected,
            file: file,
            line: line
        )
    }
}
