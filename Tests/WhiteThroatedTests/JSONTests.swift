import Foundation
import XCTest
@testable import WhiteThroated
import NIOCore
import NIOHTTP1

private struct TestPayload: Codable, Equatable {
    let id: Int
    let name: String
}

final class JSONTests: XCTestCase {
    func testRequestDecodesCodableJSON() throws {
        let payload = #"{"id":42,"name":"WhiteThroated"}"#
        var body = ByteBufferAllocator().buffer(
            capacity: payload.utf8.count
        )
        body.writeString(payload)

        let request = Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .POST,
                uri: "/"
            ),
            body: body
        )

        let decoded: TestPayload = try request.decodeJSON()

        XCTAssertEqual(
            decoded,
            TestPayload(
                id: 42,
                name: "WhiteThroated"
            )
        )
    }

    func testEmptyJSONBodyThrows() {
        let request = Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .POST,
                uri: "/"
            ),
            body: ByteBufferAllocator().buffer(capacity: 0)
        )

        XCTAssertThrowsError(
            try request.decodeJSON(TestPayload.self)
        ) { error in
            guard case RequestDecodingError.emptyBody = error else {
                return XCTFail(
                    "Expected RequestDecodingError.emptyBody"
                )
            }
        }
    }

    func testResponseEncodesCodableJSON() throws {
        let response = try Response.json(
            TestPayload(
                id: 42,
                name: "WhiteThroated"
            )
        )

        XCTAssertEqual(
            response.headers.first(name: "content-type"),
            "application/json; charset=utf-8"
        )

        guard case .buffer(let buffer) = response.body else {
            return XCTFail("Expected ByteBuffer JSON body")
        }

        let data = Data(buffer.readableBytesView)
        let decoded = try JSONDecoder().decode(
            TestPayload.self,
            from: data
        )

        XCTAssertEqual(
            decoded,
            TestPayload(
                id: 42,
                name: "WhiteThroated"
            )
        )
    }

    func testPreparedResponseEncodesCodableJSON() throws {
        let prepared = try PreparedResponse.json(
            TestPayload(
                id: 7,
                name: "fast"
            )
        )

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-type"
            ),
            "application/json; charset=utf-8"
        )
        XCTAssertNotNil(prepared.bodyBuffer)
    }

    func testRedirectResponse() {
        let response = Response.redirect("/login")

        XCTAssertEqual(
            response.status,
            .seeOther
        )
        XCTAssertEqual(
            response.headers.first(name: "location"),
            "/login"
        )
    }

    func testHTMLResponse() {
        let response = Response.html("<h1>WhiteThroated</h1>")

        XCTAssertEqual(
            response.headers.first(name: "content-type"),
            "text/html; charset=utf-8"
        )
    }
}
