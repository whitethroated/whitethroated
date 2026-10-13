import XCTest
@testable import Hudhud
import NIOCore
import NIOHTTP1

final class CookieTests: XCTestCase {
    func testRequestReadsCookieLazily() {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/"
        )
        head.headers.add(
            name: "cookie",
            value: "session=abc123; theme=dark"
        )

        let request = Request(
            head: head,
            body: ByteBufferAllocator().buffer(capacity: 0)
        )

        XCTAssertEqual(
            request.cookie("session"),
            "abc123"
        )
        XCTAssertEqual(
            request.cookie("theme"),
            "dark"
        )
        XCTAssertNil(
            request.cookie("missing")
        )
    }

    func testRequestCookieTrimsOptionalWhitespace() {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/"
        )
        head.headers.add(
            name: "cookie",
            value: "a = one ; b= two "
        )

        let request = Request(
            head: head,
            body: ByteBufferAllocator().buffer(capacity: 0)
        )

        XCTAssertEqual(request.cookie("a"), "one")
        XCTAssertEqual(request.cookie("b"), "two")
    }

    func testResponseSetsCookie() {
        var response = Response.text("ok")

        response.setCookie(
            "session",
            value: "abc123",
            options: CookieOptions(
                path: "/",
                maxAgeSeconds: 3_600,
                httpOnly: true,
                secure: true,
                sameSite: .lax
            )
        )

        XCTAssertEqual(
            response.headers.first(name: "set-cookie"),
            "session=abc123; Path=/; Max-Age=3600; HttpOnly; Secure; SameSite=Lax"
        )
    }

    func testResponseClearsCookie() {
        var response = Response.noContent()

        response.clearCookie(
            "session",
            path: "/"
        )

        XCTAssertEqual(
            response.headers.first(name: "set-cookie"),
            "session=; Path=/; Max-Age=0"
        )
    }
}
