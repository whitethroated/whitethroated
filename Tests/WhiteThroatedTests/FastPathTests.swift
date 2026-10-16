import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class FastPathTests: XCTestCase {
    func testSynchronousRouteUsesImmediateResult() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/") { _ in
            .text("fast")
        }

        let result = app.respondFast(
            to: makeRequest(path: "/"),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Expected synchronous route to use immediate path"
            )
        }

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "fast")
    }

    func testFutureRoutePreservesAsynchronousPath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/async") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("async")
            )
        }

        let result = app.respondFast(
            to: makeRequest(path: "/async"),
            on: loop
        )

        guard case .future = result else {
            return XCTFail(
                "Expected asynchronous route to use future path"
            )
        }
    }

    func testMiddlewarePromotesImmediateRouteToFuture() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.use { request, _, next in
            next(request)
        }

        app.get("/") { _ in
            .text("middleware")
        }

        let result = app.respondFast(
            to: makeRequest(path: "/"),
            on: loop
        )

        guard case .future = result else {
            return XCTFail(
                "Expected middleware pipeline to use future path"
            )
        }
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
