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

    func testDeepStaticRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/a/b/c/d/e/f/g/h",
            response: .text("deep")
        )

        let response = try app
            .respond(
                to: makeRequest(
                    path: "/a/b/c/d/e/f/g/h"
                ),
                on: loop
            )
            .wait()

        XCTAssertTextBody(response, equals: "deep")
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

    func testRouterFallsBackToParameterWhenStaticBranchDeadEnds() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/me/settings") { _ in
            .text("settings")
        }

        app.get("/users/:id/profile") { request in
            .text(request.parameter("id") ?? "")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/users/me/profile"),
                on: loop
            )
            .wait()

        XCTAssertTextBody(response, equals: "me")
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

    func testHeadFallsBackToGetRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/resource") { _ in
            .text("get")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/resource", method: .HEAD),
                on: loop
            )
            .wait()

        XCTAssertTextBody(response, equals: "get")
    }

    func testExplicitHeadRouteWinsOverGetFallback() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/resource") { _ in
            .text("get")
        }

        app.head("/resource") { _ in
            .text("head")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/resource", method: .HEAD),
                on: loop
            )
            .wait()

        XCTAssertTextBody(response, equals: "head")
    }

    func testUnsupportedMethodDoesNotFallThroughToGet() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/resource") { _ in
            .text("get")
        }

        let response = try app
            .respond(
                to: makeRequest(path: "/resource", method: .CONNECT),
                on: loop
            )
            .wait()

        XCTAssertEqual(response.status, .notFound)
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

    func testQueryAfterDeepStaticRouteDoesNotAffectRouting() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/a/b/c/d/e/f/g/h",
            response: .text("deep")
        )

        let response = try app
            .respond(
                to: makeRequest(
                    path: "/a/b/c/d/e/f/g/h?q=1"
                ),
                on: loop
            )
            .wait()

        XCTAssertTextBody(response, equals: "deep")
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
        switch response.body {
        case .text(let body):
            XCTAssertEqual(
                body,
                expected,
                file: file,
                line: line
            )

        case .buffer(let buffer):
            let body = buffer.getString(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            )
            XCTAssertEqual(
                body,
                expected,
                file: file,
                line: line
            )

        default:
            XCTFail(
                "Expected text-compatible response",
                file: file,
                line: line
            )
        }
    }
}
