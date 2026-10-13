import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class RouteGroupTests: XCTestCase {
    func testGroupPrefixesRoutesAtRegistrationTime() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let api = app.group("/api/v1")

        api.get(
            "/health",
            response: .text("ok")
        )

        let response = try app.respond(
            to: makeRequest(path: "/api/v1/health"),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "ok")
    }

    func testNestedGroupsComposePrefixes() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let api = app.group("api")
        let users = api.group("/v1/users/")

        users.get("/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let response = try app.respond(
            to: makeRequest(path: "/api/v1/users/42"),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "42")
    }

    func testGroupRootMapsToPrefixItself() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let api = app.group("/api/")

        api.get(
            "/",
            response: .text("root")
        )

        let response = try app.respond(
            to: makeRequest(path: "/api"),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "root")
    }

    func testGroupSupportsAsyncHandlers() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let api = app.group("/api")

        api.post("/jobs") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("queued")
            )
        }

        let response = try app.respond(
            to: makeRequest(
                path: "/api/jobs",
                method: .POST
            ),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "queued")
    }

    private func makeRequest(
        path: String,
        method: NIOHTTP1.HTTPMethod = .GET
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
