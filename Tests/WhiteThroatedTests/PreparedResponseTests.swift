import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class PreparedResponseTests: XCTestCase {
    func testPreparedRouteUsesPreparedFastPath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/prepared",
            response: .text("Hello, World!")
        )

        let result = app.respondFast(
            to: makeRequest(path: "/prepared"),
            on: loop
        )

        guard case .prepared(let prepared) = result else {
            return XCTFail(
                "Prepared route should use the prepared path"
            )
        }

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "13"
        )

        guard let buffer = prepared.bodyBuffer else {
            return XCTFail(
                "Prepared response should store a ByteBuffer"
            )
        }

        XCTAssertEqual(
            buffer.getString(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            ),
            "Hello, World!"
        )
    }

    func testPreparedResponseCanBridgeToFutureAPI() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/prepared",
            response: .text("payload")
        )

        let response = try app.respond(
            to: makeRequest(path: "/prepared"),
            on: loop
        ).wait()

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(
            response.headers.first(name: "content-length"),
            "7"
        )
    }

    func testPreparedHeadFallsBackToPreparedGet() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/prepared",
            response: .text("payload")
        )

        let response = try app.respond(
            to: makeRequest(
                path: "/prepared",
                method: .HEAD
            ),
            on: loop
        ).wait()

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(
            response.headers.first(name: "content-length"),
            "7"
        )
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
}
