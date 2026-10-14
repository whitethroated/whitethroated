import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ExactStaticRouterTests: XCTestCase {
    func testStaticRouteMatchesWithQueryString() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/health",
            response: .text("ok")
        )

        let response = try app.respond(
            to: makeRequest(
                method: .GET,
                uri: "/health?verbose=1"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "ok"
        )
    }

    func testDuplicateStaticRegistrationUsesLatestEndpoint()
        throws
    {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/version",
            response: .text("old")
        )
        app.get(
            "/version",
            response: .text("new")
        )

        let response = try app.respond(
            to: makeRequest(
                method: .GET,
                uri: "/version"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "new"
        )
    }

    func testTrailingSlashFallsBackToTrieSemantics()
        throws
    {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/health",
            response: .text("ok")
        )

        let response = try app.respond(
            to: makeRequest(
                method: .GET,
                uri: "/health/"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "ok"
        )
    }

    func testHeadDynamicRouteBeatsGetExactFallback()
        throws
    {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/users/me",
            response: .text("get-static")
        )

        app.head("/users/:id") { request in
            .text(
                "head:"
                + (request.parameter("id") ?? "")
            )
        }

        let response = try app.respond(
            to: makeRequest(
                method: .HEAD,
                uri: "/users/me"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "head:me"
        )
    }

    func testHeadFallsBackToGetExactRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/health",
            response: .text("get")
        )

        let response = try app.respond(
            to: makeRequest(
                method: .HEAD,
                uri: "/health"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "get"
        )
    }

    func testCustomMethodStaticRouteUsesExactLookup()
        throws
    {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.on(
            .other("PROPFIND"),
            "/dav",
            response: .text("dav")
        )

        let response = try app.respond(
            to: makeRequest(
                method: .RAW(
                    value: "PROPFIND"
                ),
                uri: "/dav"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "dav"
        )
    }

    func testRootStaticRouteUsesExactLookup() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/",
            response: .text("root")
        )

        let response = try app.respond(
            to: makeRequest(
                method: .GET,
                uri: "/?a=1"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "root"
        )
    }

    func testDynamicRouteStillMatchesWhenMethodHasStaticRoutes()
        throws
    {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/health",
            response: .text("ok")
        )

        app.get("/users/:id") { request in
            .text(
                request.parameter("id") ?? ""
            )
        }

        let response = try app.respond(
            to: makeRequest(
                method: .GET,
                uri: "/users/42"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "42"
        )
    }

    private func makeRequest(
        method: NIOHTTP1.HTTPMethod,
        uri: String
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: uri
            ),
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
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
