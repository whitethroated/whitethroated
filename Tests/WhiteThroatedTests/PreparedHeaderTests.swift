import XCTest
@testable import WhiteThroated
import NIOHTTP1

final class PreparedHeaderTests: XCTestCase {
    func testPreparedHeaderRebuildsCachedHead() {
        let prepared = PreparedResponse
            .text("ok")
            .header(
                "cache-control",
                "public, max-age=60"
            )

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "cache-control"
            ),
            "public, max-age=60"
        )
        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "2"
        )
    }

    func testPreparedCookieLivesInCachedHead() {
        let prepared = PreparedResponse
            .text("ok")
            .cookie(
                "session",
                value: "abc",
                options: CookieOptions(
                    path: "/",
                    httpOnly: true,
                    secure: true,
                    sameSite: .lax
                )
            )

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "set-cookie"
            ),
            "session=abc; Path=/; HttpOnly; Secure; SameSite=Lax"
        )
    }

    func testPreparedRedirectHasNoBody() {
        let prepared = PreparedResponse.redirect("/login")

        XCTAssertEqual(
            prepared.http11Head.status,
            .seeOther
        )
        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "location"
            ),
            "/login"
        )
        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "0"
        )
        XCTAssertNil(prepared.bodyBuffer)
    }

    func testResponseHeaderHelpers() {
        var response = Response.text("ok")

        response.setHeader(
            "x-request-id",
            "123"
        )
        response.appendHeader(
            "vary",
            "accept-encoding"
        )

        XCTAssertEqual(
            response.headers.first(name: "x-request-id"),
            "123"
        )
        XCTAssertEqual(
            response.headers.first(name: "vary"),
            "accept-encoding"
        )
    }
}
