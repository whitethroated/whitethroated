import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class MiddlewareTests: XCTestCase {
    func testMiddlewareExecutesInRegistrationOrder() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.use { request, _, next in
            next(request).map { response in
                var response = response
                response.headers.add(
                    name: "x-first",
                    value: "1"
                )
                return response
            }
        }

        app.use { request, _, next in
            next(request).map { response in
                var response = response
                response.headers.add(
                    name: "x-second",
                    value: "2"
                )
                return response
            }
        }

        app.get("/") { _ in
            .text("ok")
        }

        let response = try app
            .respond(to: makeRequest(path: "/"), on: loop)
            .wait()

        XCTAssertEqual(
            response.headers.first(name: "x-first"),
            "1"
        )
        XCTAssertEqual(
            response.headers.first(name: "x-second"),
            "2"
        )
    }

    func testMiddlewareCanShortCircuitRouter() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.use { _, context, _ in
            context.eventLoop.makeSucceededFuture(
                .text(
                    "blocked",
                    status: .unauthorized
                )
            )
        }

        app.get("/") { _ in
            .text("route")
        }

        let response = try app
            .respond(to: makeRequest(path: "/"), on: loop)
            .wait()

        XCTAssertEqual(response.status, .unauthorized)

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "blocked")
    }

    func testFastMiddlewarePreservesImmediateRoute() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.useFast { request, _, next in
            next(request)
        }

        app.get("/") { _ in
            .text("ok")
        }

        let result = app.respondFast(
            to: makeRequest(path: "/"),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Fast middleware should preserve immediate route"
            )
        }

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "ok")
    }

    func testFastMiddlewarePreservesPreparedRoute() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.useFast { request, _, next in
            next(request)
        }

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let result = app.respondFast(
            to: makeRequest(path: "/prepared"),
            on: loop
        )

        guard case .prepared = result else {
            return XCTFail(
                "Pass-through fast middleware should preserve prepared route"
            )
        }
    }

    func testFastMiddlewareCanMapImmediateResponse() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.useFast { request, _, next in
            next(request).map { response in
                var response = response
                response.headers.add(
                    name: "x-fast",
                    value: "1"
                )
                return response
            }
        }

        app.get("/") { _ in
            .text("ok")
        }

        let result = app.respondFast(
            to: makeRequest(path: "/"),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Mapped synchronous response should remain immediate"
            )
        }

        XCTAssertEqual(
            response.headers.first(name: "x-fast"),
            "1"
        )
    }

    func testFastMiddlewareCanShortCircuitSynchronously() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.useFast { _, _, _ in
            .response(
                .text(
                    "blocked",
                    status: .unauthorized
                )
            )
        }

        app.get("/") { _ in
            .text("route")
        }

        let result = app.respondFast(
            to: makeRequest(path: "/"),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Fast short circuit should remain immediate"
            )
        }

        XCTAssertEqual(
            response.status,
            .unauthorized
        )
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
