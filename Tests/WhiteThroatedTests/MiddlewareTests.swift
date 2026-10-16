import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class MiddlewareOrderBox:
    @unchecked Sendable
{
    var values: [String] = []
}

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

    func testMultipleFastMiddlewarePreservePreparedRoute() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        for _ in 0..<8 {
            app.useFast { request, _, next in
                next(request)
            }
        }

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let result = app.respondFast(
            to: makeRequest(
                path: "/prepared"
            ),
            on: loop
        )

        guard case .prepared = result else {
            return XCTFail(
                "Fast middleware chain should preserve prepared route"
            )
        }
    }

    func testMixedFastAndAsyncMiddlewarePreserveOrder() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let order = MiddlewareOrderBox()

        app.useFast { request, _, next in
            order.values.append(
                "fast-before"
            )
            let result = next(request)
            order.values.append(
                "fast-after"
            )
            return result
        }

        app.use { request, _, next in
            order.values.append(
                "async-before"
            )
            return next(request).map { response in
                order.values.append(
                    "async-after"
                )
                return response
            }
        }

        app.get("/") { _ in
            order.values.append(
                "handler"
            )
            return .text("ok")
        }

        _ = try app
            .respond(
                to: makeRequest(path: "/"),
                on: loop
            )
            .wait()

        XCTAssertEqual(
            order.values,
            [
                "fast-before",
                "async-before",
                "handler",
                "async-after",
                "fast-after"
            ]
        )
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
