import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class RouterHotPathTests: XCTestCase {
    func testTerminalStaticRouteStillMatchesQuery() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/health",
            response: .text("ok")
        )

        let response = try app.respond(
            to: makeRequest("/health?verbose=1"),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "ok")
    }

    func testTerminalParameterRouteMatchesWithoutStaticSibling() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let response = try app.respond(
            to: makeRequest("/users/42"),
            on: loop
        ).wait()

        XCTAssertBody(response, equals: "42")
    }

    func testParameterBranchStillBacktracksToCatchAll() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/files/:id/edit") { request in
            .text(
                "edit:" + (request.parameter("id") ?? "")
            )
        }

        app.get("/files/*path") { request in
            .text(
                "all:" + (request.parameter("path") ?? "")
            )
        }

        let response = try app.respond(
            to: makeRequest("/files/a/b/c"),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "all:a/b/c"
        )
    }

    func testTrieStaticChildTableResizesAcrossLargeFanOut()
        throws
    {
        let app = Application()
        let loop = EmbeddedEventLoop()

        for index in 0..<4_096 {
            app.get(
                "/fanout/r\(index)",
                response: .text(
                    String(index)
                )
            )
        }

        for index in [
            0,
            15,
            255,
            1_023,
            4_095
        ] {
            let response = try app
                .respond(
                    to: makeRequest(
                        path:
                            "/fanout/r\(index)/"
                    ),
                    on: loop
                )
                .wait()

            XCTAssertTextBody(
                response,
                equals: String(index)
            )
        }
    }

    func testTrieStaticChildTablePreservesStaticPriorityOverParameter()
        throws
    {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(
                "dynamic:"
                + (request.parameter("id") ?? "")
            )
        }

        app.get(
            "/users/me",
            response: .text("static")
        )

        let response = try app
            .respond(
                to: makeRequest(
                    path: "/users/me/"
                ),
                on: loop
            )
            .wait()

        XCTAssertTextBody(
            response,
            equals: "static"
        )
    }

    func testCatchAllOnlyBranchCapturesRemainingPathAndQueryStopsCapture() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/assets/*path") { request in
            .text(request.parameter("path") ?? "")
        }

        let response = try app.respond(
            to: makeRequest(
                "/assets/images/icons/app.png?v=3"
            ),
            on: loop
        ).wait()

        XCTAssertBody(
            response,
            equals: "images/icons/app.png"
        )
    }

    private func makeRequest(
        _ uri: String
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: uri
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
        guard case .text(let body) = response.body else {
            return XCTFail(
                "Expected text body",
                file: file,
                line: line
            )
        }

        XCTAssertEqual(
            body,
            expected,
            file: file,
            line: line
        )
    }
}
