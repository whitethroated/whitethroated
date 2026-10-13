import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class TransportFastPathTests: XCTestCase {
    func testPreparedRouteResolvesWithoutRequestDispatch() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/prepared"
        )

        let result = app.respondTransport(
            method: .get,
            head: head,
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

    func testTransportBuildsRequestForHandler() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/users/42"
        )

        let result = app.respondTransport(
            method: .get,
            head: head,
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Expected immediate handler response"
            )
        }

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "42")
    }

    func testMiddlewareDisablesPreparedTransportBypass() {
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

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/prepared"
        )

        let result = app.respondTransport(
            method: .get,
            head: head,
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
}
