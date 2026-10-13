import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class TransportFastPathTests: XCTestCase {
    func testPreparedRouteResolvesThroughPreparedPath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let result = app.respondTransport(
            head: makeHead(path: "/prepared"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .prepared(let prepared) = result else {
            return XCTFail(
                "Expected transport prepared fast path"
            )
        }

        XCTAssertEqual(
            prepared.http11Head.status,
            .ok
        )
    }

    func testSynchronousRouteUsesDirectSyncPath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let result = app.respondTransport(
            head: makeHead(path: "/users/42"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Expected immediate synchronous response"
            )
        }

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "42")
    }

    func testAsynchronousRouteUsesDirectFuturePath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/async") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("async")
            )
        }

        let result = app.respondTransport(
            head: makeHead(path: "/async"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .future = result else {
            return XCTFail(
                "Expected future asynchronous response"
            )
        }
    }

    func testMiddlewareDisablesDirectTransportDispatch() {
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

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let result = app.respondTransport(
            head: makeHead(path: "/prepared"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Middleware must participate in transport dispatch"
            )
        }

        XCTAssertEqual(
            response.status,
            .unauthorized
        )
    }

    private func makeHead(path: String) -> HTTPRequestHead {
        HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: path
        )
    }
}
