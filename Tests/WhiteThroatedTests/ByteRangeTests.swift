import XCTest
@testable import WhiteThroated
import NIOCore
import NIOHTTP1
import NIOPosix

final class ByteRangeTests: XCTestCase {
    func testNoRangeHeader() {
        let request = makeRequest()

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .none
        )
    }

    func testClosedByteRange() {
        let request = makeRequest(
            range: "bytes=100-199"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .satisfiable(100..<200)
        )
    }

    func testOpenEndedByteRange() {
        let request = makeRequest(
            range: "bytes=900-"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .satisfiable(900..<1_000)
        )
    }

    func testSuffixByteRange() {
        let request = makeRequest(
            range: "bytes=-250"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .satisfiable(750..<1_000)
        )
    }

    func testSuffixLargerThanRepresentationUsesWholeBody() {
        let request = makeRequest(
            range: "bytes=-2000"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .satisfiable(0..<1_000)
        )
    }

    func testEndBeyondRepresentationIsClamped() {
        let request = makeRequest(
            range: "bytes=950-5000"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .satisfiable(950..<1_000)
        )
    }

    func testStartBeyondRepresentationIsUnsatisfiable() {
        let request = makeRequest(
            range: "bytes=1000-1200"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .unsatisfiable
        )
    }

    func testRangeOnEmptyRepresentationIsUnsatisfiable() {
        let request = makeRequest(
            range: "bytes=0-0"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 0
            ),
            .unsatisfiable
        )
    }

    func testDuplicateRangeHeadersAreExplicitlyUnsupported() {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/file"
        )
        head.headers.add(
            name: "range",
            value: "bytes=0-9"
        )
        head.headers.add(
            name: "range",
            value: "bytes=20-29"
        )

        let request = Request(
            head: head,
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .unsupportedMultiple
        )
    }

    func testMultipleRangesAreExplicitlyUnsupported() {
        let request = makeRequest(
            range: "bytes=0-9,20-29"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .unsupportedMultiple
        )
    }

    func testUnsupportedRangeUnit() {
        let request = makeRequest(
            range: "items=0-9"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .unsupportedUnit
        )
    }

    func testMalformedRange() {
        let request = makeRequest(
            range: "bytes=20-10"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .malformed
        )
    }

    func testRangeIntegerOverflowIsMalformed() {
        let request = makeRequest(
            range:
                "bytes=999999999999999999999999999999-"
        )

        XCTAssertEqual(
            request.byteRange(
                totalLength: 1_000
            ),
            .malformed
        )
    }

    func testPartialFileRegionBuilds206HeadersAndSlice() throws {
        let handle = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: -1
        )

        // The fake descriptor is never a real open file; release
        // ownership so debug builds don't trip the leaked-handle
        // assertion on deinit.
        defer {
            _ = try? handle.takeDescriptorOwnership()
        }
        let region = FileRegion(
            fileHandle: handle,
            readerIndex: 100,
            endIndex: 1_100
        )

        let response = Response.partialFileRegion(
            region,
            range: 200..<300,
            contentType: "video/mp4"
        )

        XCTAssertEqual(
            response.status,
            .partialContent
        )
        XCTAssertEqual(
            response.headers.first(
                name: "accept-ranges"
            ),
            "bytes"
        )
        XCTAssertEqual(
            response.headers.first(
                name: "content-range"
            ),
            "bytes 200-299/1000"
        )

        guard case .fileRegion(let slice) =
            response.body
        else {
            return XCTFail(
                "Expected FileRegion body"
            )
        }

        XCTAssertEqual(
            slice.readerIndex,
            300
        )
        XCTAssertEqual(
            slice.endIndex,
            400
        )
        XCTAssertEqual(
            slice.readableBytes,
            100
        )
    }

    func testRangeNotSatisfiableResponse() {
        let response =
            Response.rangeNotSatisfiable(
                totalLength: 1_000
            )

        XCTAssertEqual(
            response.status,
            .rangeNotSatisfiable
        )
        XCTAssertEqual(
            response.headers.first(
                name: "content-range"
            ),
            "bytes */1000"
        )
        XCTAssertEqual(
            response.headers.first(
                name: "accept-ranges"
            ),
            "bytes"
        )
    }

    private func makeRequest(
        range: String? = nil
    ) -> Request {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/file"
        )

        if let range {
            head.headers.add(
                name: "range",
                value: range
            )
        }

        return Request(
            head: head,
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )
    }
}
