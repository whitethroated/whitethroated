import XCTest
@testable import WhiteThroated
import NIOHTTP1

final class PreparedResponseStorageTests: XCTestCase {
    func testPreparedResponseUsesSharedImmutableStorage() {
        let prepared = PreparedResponse.text("ok")
        let copy = prepared

        XCTAssertTrue(
            prepared.storage === copy.storage
        )
    }

    func testPreparedMutationHelperCreatesIndependentStorage() {
        let original = PreparedResponse.text("ok")
        let modified = original.header(
            "cache-control",
            "no-store"
        )

        XCTAssertFalse(
            original.storage === modified.storage
        )
        XCTAssertNil(
            original.http11Head.headers.first(
                name: "cache-control"
            )
        )
        XCTAssertEqual(
            modified.http11Head.headers.first(
                name: "cache-control"
            ),
            "no-store"
        )
    }

    func testNoContentCachesNormalizedHTTP11Head() {
        let prepared = PreparedResponse
            .text(
                "payload",
                status: .noContent
            )
            .header(
                "transfer-encoding",
                "chunked"
            )

        XCTAssertEqual(
            prepared.http11Head.status,
            .noContent
        )
        XCTAssertNil(
            prepared.http11Head.headers.first(
                name: "content-length"
            )
        )
        XCTAssertNil(
            prepared.http11Head.headers.first(
                name: "transfer-encoding"
            )
        )
    }

    func testBodylessPreparedStorageDropsCachedWriterBody() {
        let noContent = PreparedResponse.text(
            "payload",
            status: .noContent
        )
        let notModified = PreparedResponse.text(
            "payload",
            status: .notModified
        )
        let emptyOK = PreparedResponse.text("")

        XCTAssertNil(noContent.bodyBuffer)
        XCTAssertNil(notModified.bodyBuffer)
        XCTAssertNil(emptyOK.bodyBuffer)
    }

    func testNotModifiedContentLengthMutationKeepsRepresentationLength() {
        let prepared = PreparedResponse
            .text(
                "payload",
                status: .notModified
            )
            .header(
                "content-length",
                "999"
            )

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "7"
        )
        XCTAssertNil(prepared.bodyBuffer)
    }

    func testNotModifiedCachedHeadKeepsRepresentationLength() {
        let prepared = PreparedResponse.text(
            "payload",
            status: .notModified
        )

        XCTAssertEqual(
            prepared.http11Head.status,
            .notModified
        )
        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "7"
        )
    }

    func testOrdinaryPreparedHeadKeepsBodyLength() {
        let prepared = PreparedResponse.text("payload")

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "7"
        )
    }

    func testFallbackResponseAndCachedBodyShareContents() {
        let prepared = PreparedResponse.text(
            "Hello, World!"
        )

        guard
            case .buffer(let responseBody) =
                prepared.response.body,
            let cachedBody = prepared.bodyBuffer
        else {
            return XCTFail(
                "Expected prepared buffer storage"
            )
        }

        XCTAssertEqual(
            responseBody.readableBytes,
            cachedBody.readableBytes
        )
        XCTAssertEqual(
            responseBody.getString(
                at: responseBody.readerIndex,
                length: responseBody.readableBytes
            ),
            "Hello, World!"
        )
    }
}
