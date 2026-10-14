import XCTest
@testable import Hudhud
import NIOCore
import NIOHTTP1

final class EntityTagTests: XCTestCase {
    func testStrongAndWeakHeaderValues() {
        XCTAssertEqual(
            EntityTag("abc123").headerValue,
            #""abc123""#
        )
        XCTAssertEqual(
            EntityTag.weak("abc123").headerValue,
            #"W/"abc123""#
        )
    }

    func testIfNoneMatchHeaderNameIsCaseInsensitive() {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/resource"
        )
        head.headers.add(
            name: "If-NoNe-MaTcH",
            value: #""abc123""#
        )

        let request = Request(
            head: head,
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )

        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag("abc123")
            )
        )
    }

    func testIfNoneMatchScansMultipleHeaderFieldsWithoutCanonicalSplit() {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/resource"
        )
        head.headers.add(
            name: "if-none-match",
            value: #""first""#
        )
        head.headers.add(
            name: "if-none-match",
            value: #"W/"second""#
        )

        let request = Request(
            head: head,
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )

        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag("second")
            )
        )
    }

    func testIfNoneMatchStrongMatch() {
        let request = makeRequest(
            ifNoneMatch: #""abc123""#
        )

        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag("abc123")
            )
        )
    }

    func testIfNoneMatchUsesWeakComparison() {
        let request = makeRequest(
            ifNoneMatch: #"W/"abc123""#
        )

        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag("abc123")
            )
        )
        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag.weak("abc123")
            )
        )
    }

    func testIfNoneMatchList() {
        let request = makeRequest(
            ifNoneMatch:
                #""first", W/"second", "third""#
        )

        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag("second")
            )
        )
        XCTAssertFalse(
            request.matchesIfNoneMatch(
                EntityTag("missing")
            )
        )
    }

    func testIfNoneMatchWildcard() {
        let request = makeRequest(
            ifNoneMatch: "*"
        )

        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag("anything")
            )
        )
    }

    func testCommaInsideOpaqueTagIsNotSplit() {
        let request = makeRequest(
            ifNoneMatch:
                #""hello,world", "other""#
        )

        XCTAssertTrue(
            request.matchesIfNoneMatch(
                EntityTag("hello,world")
            )
        )
    }

    func testMatchingTagWithMalformedTrailingBytesDoesNotMatch() {
        let request = makeRequest(
            ifNoneMatch: #""abc123"junk"#
        )

        XCTAssertFalse(
            request.matchesIfNoneMatch(
                EntityTag("abc123")
            )
        )
    }

    func testMalformedIfNoneMatchDoesNotMatch() {
        let request = makeRequest(
            ifNoneMatch: #"abc123"#
        )

        XCTAssertFalse(
            request.matchesIfNoneMatch(
                EntityTag("abc123")
            )
        )
    }

    func testResponseETagHelper() {
        let response = Response
            .text("ok")
            .etag(
                EntityTag("abc123")
            )

        XCTAssertEqual(
            response.headers.first(
                name: "etag"
            ),
            #""abc123""#
        )
    }

    func testNotModifiedHelper() {
        let response = Response.notModified(
            etag: EntityTag.weak("abc123")
        )

        XCTAssertEqual(
            response.status,
            .notModified
        )
        XCTAssertEqual(
            response.headers.first(
                name: "etag"
            ),
            #"W/"abc123""#
        )
    }

    func testPreparedETagKeepsCachedHeadInSync() {
        let prepared = PreparedResponse
            .text("ok")
            .etag(
                EntityTag("abc123")
            )

        XCTAssertEqual(
            prepared.response.headers.first(
                name: "etag"
            ),
            #""abc123""#
        )
        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "etag"
            ),
            #""abc123""#
        )
    }

    private func makeRequest(
        ifNoneMatch value: String
    ) -> Request {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/resource"
        )
        head.headers.add(
            name: "if-none-match",
            value: value
        )

        return Request(
            head: head,
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )
    }
}
