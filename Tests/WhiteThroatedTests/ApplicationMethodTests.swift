import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ApplicationMethodTests: XCTestCase {
    func testPreparedPostRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.post(
            "/submit",
            response: .text("posted")
        )

        let response = try app.respond(
            to: makeRequest(
                path: "/submit",
                method: .POST
            ),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "posted")
    }

    func testAsyncPutRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.put("/resource") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("put")
            )
        }

        let response = try app.respond(
            to: makeRequest(
                path: "/resource",
                method: .PUT
            ),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "put")
    }

    func testAsyncPatchDeleteHeadAndOptionsRoutes() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.patch("/resource") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("patch")
            )
        }

        app.delete("/resource") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("delete")
            )
        }

        app.head("/resource") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("head")
            )
        }

        app.options("/resource") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("options")
            )
        }

        XCTAssertBody(
            try app.respond(
                to: makeRequest(
                    path: "/resource",
                    method: .PATCH
                ),
                on: loop
            ).wait(),
            equals: "patch"
        )

        XCTAssertBody(
            try app.respond(
                to: makeRequest(
                    path: "/resource",
                    method: .DELETE
                ),
                on: loop
            ).wait(),
            equals: "delete"
        )

        XCTAssertBody(
            try app.respond(
                to: makeRequest(
                    path: "/resource",
                    method: .HEAD
                ),
                on: loop
            ).wait(),
            equals: "head"
        )

        XCTAssertBody(
            try app.respond(
                to: makeRequest(
                    path: "/resource",
                    method: .OPTIONS
                ),
                on: loop
            ).wait(),
            equals: "options"
        )
    }

    func testConnectAndTraceRoutes() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.connect("/tunnel") { _ in
            .text("connect")
        }

        app.trace("/trace") { _ in
            .text("trace")
        }

        XCTAssertBody(
            try app.respond(
                to: makeRequest(
                    path: "/tunnel",
                    method: .CONNECT
                ),
                on: loop
            ).wait(),
            equals: "connect"
        )

        XCTAssertBody(
            try app.respond(
                to: makeRequest(
                    path: "/trace",
                    method: .TRACE
                ),
                on: loop
            ).wait(),
            equals: "trace"
        )
    }

    private func makeRequest(
        path: String,
        method: NIOHTTP1.HTTPMethod
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: path
            ),
            body: ByteBufferAllocator().buffer(capacity: 0)
        )
    }

    private func XCTAssertBody(
        _ response: Response,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch response.body {
        case .text(let value):
            XCTAssertEqual(
                value,
                expected,
                file: file,
                line: line
            )

        case .buffer(let buffer):
            XCTAssertEqual(
                buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ),
                expected,
                file: file,
                line: line
            )

        default:
            XCTFail(
                "Expected text-compatible body",
                file: file,
                line: line
            )
        }
    }
}
