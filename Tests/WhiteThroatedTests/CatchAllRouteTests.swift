import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class CatchAllRouteTests: XCTestCase {
    func testCatchAllCapturesRemainingPath() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/files/*path") { request in
            .text(request.parameter("path") ?? "")
        }

        let response = try app.respond(
            to: makeRequest(
                path: "/files/images/2026/avatar.png"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "images/2026/avatar.png"
        )
    }

    func testCatchAllExcludesQueryString() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/files/*path") { request in
            .text(request.parameter("path") ?? "")
        }

        let response = try app.respond(
            to: makeRequest(
                path: "/files/a/b.txt?download=1"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "a/b.txt"
        )
    }

    func testStaticRouteWinsOverCatchAll() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/files/*path"
        ) { _ in
            .text("catch-all")
        }

        app.get(
            "/files/public"
        ) { _ in
            .text("static")
        }

        let response = try app.respond(
            to: makeRequest(path: "/files/public"),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "static")
    }

    func testParameterBranchWinsBeforeCatchAll() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/files/:id/edit"
        ) { request in
            .text(
                "edit:" + (request.parameter("id") ?? "")
            )
        }

        app.get(
            "/files/*path"
        ) { request in
            .text(
                "catch:" + (request.parameter("path") ?? "")
            )
        }

        let parameterResponse = try app.respond(
            to: makeRequest(path: "/files/42/edit"),
            on: loop
        ).wait()

        let fallbackResponse = try app.respond(
            to: makeRequest(path: "/files/a/b/c"),
            on: loop
        ).wait()

        XCTAssertBody(
            parameterResponse,
            equals: "edit:42"
        )
        XCTAssertBody(
            fallbackResponse,
            equals: "catch:a/b/c"
        )
    }

    func testCatchAllRequiresAtLeastOneRemainingByte() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/files/*path") { _ in
            .text("matched")
        }

        let response = try app.respond(
            to: makeRequest(path: "/files"),
            on: loop
        ).wait()

        XCTAssertEqual(
            response.status,
            .notFound
        )
    }

    private func makeRequest(path: String) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .GET,
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
        guard case .text(let value) = response.body else {
            return XCTFail(
                "Expected text response",
                file: file,
                line: line
            )
        }

        XCTAssertEqual(
            value,
            expected,
            file: file,
            line: line
        )
    }
}
