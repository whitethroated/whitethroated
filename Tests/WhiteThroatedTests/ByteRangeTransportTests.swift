import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ByteRangeTransportTests: XCTestCase {
    func testGetPartialFileRegionWrites206AndSlicedRegion() throws {
        let handle = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: -1
        )

        // The fake descriptor is never a real open file; release
        // ownership so debug builds don't trip the leaked-handle
        // assertion on deinit.
        defer {
            _ = try? handle.takeDescriptorOwnership()
        }
        let source = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 1_000
        )
        let app = makeApp(
            region: source
        )
        let channel = try makeChannel(app)

        try sendRequest(
            method: .GET,
            range: "bytes=100-199",
            channel: channel
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response head"
            )
        }

        XCTAssertEqual(
            head.status,
            .partialContent
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-range"
            ),
            "bytes 100-199/1000"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "100"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "accept-ranges"
            ),
            "bytes"
        )

        guard case .body(
            .fileRegion(let region)
        )? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        )
        else {
            return XCTFail(
                "Expected FileRegion body"
            )
        }

        XCTAssertEqual(
            region.readerIndex,
            100
        )
        XCTAssertEqual(
            region.endIndex,
            200
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response end"
            )
        }
    }

    func testHeadPartialFileRegionPreservesLengthAndSuppressesBody()
        throws
    {
        let handle = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: -1
        )

        // The fake descriptor is never a real open file; release
        // ownership so debug builds don't trip the leaked-handle
        // assertion on deinit.
        defer {
            _ = try? handle.takeDescriptorOwnership()
        }
        let source = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 1_000
        )
        let app = makeApp(
            region: source
        )
        let channel = try makeChannel(app)

        try sendRequest(
            method: .HEAD,
            range: "bytes=100-199",
            channel: channel
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response head"
            )
        }

        XCTAssertEqual(
            head.status,
            .partialContent
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "100"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-range"
            ),
            "bytes 100-199/1000"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response end without body"
            )
        }

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
    }

    func testUnsatisfiableRangeWrites416Metadata() throws {
        let handle = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: -1
        )

        // The fake descriptor is never a real open file; release
        // ownership so debug builds don't trip the leaked-handle
        // assertion on deinit.
        defer {
            _ = try? handle.takeDescriptorOwnership()
        }
        let source = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 1_000
        )
        let app = makeApp(
            region: source
        )
        let channel = try makeChannel(app)

        try sendRequest(
            method: .GET,
            range: "bytes=1000-",
            channel: channel
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response head"
            )
        }

        XCTAssertEqual(
            head.status,
            .rangeNotSatisfiable
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-range"
            ),
            "bytes */1000"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "0"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response end"
            )
        }
    }

    func testParserOverflowEdgesStayInSafeDirection() throws {
        // Overflowed/boundary decimal syntax must never wrap around
        // into a wrong satisfiable range and must never crash. The
        // parser is bounds-checked, so values beyond Int.max are
        // rejected as malformed; consumers map .malformed to the
        // "ignore the Range header" direction (full representation).
        func result(
            _ range: String,
            _ totalLength: Int
        ) -> ByteRangeResult {
            var head = HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/file"
            )
            head.headers.add(
                name: "range",
                value: range
            )
            let request = Request(
                head: head,
                body: ByteBufferAllocator()
                    .buffer(capacity: 0)
            )

            return request.byteRange(
                totalLength: totalLength
            )
        }

        // Decimal overflow: rejected, no wraparound.
        XCTAssertEqual(
            result("bytes=99999999999999999999999999-0", 1_000),
            .malformed
        )
        XCTAssertEqual(
            result("bytes=0-99999999999999999999999999", 1_000),
            .malformed
        )
        XCTAssertEqual(
            result("bytes=-99999999999999999999999999", 1_000),
            .malformed
        )

        // Non-digital garbage stays malformed.
        XCTAssertEqual(
            result("bytes=+0-100", 1_000),
            .malformed
        )

        // A suffix within Int range that exceeds the
        // representation saturates to the whole representation.
        XCTAssertEqual(
            result("bytes=-9223372036854775807", 1_000),
            .satisfiable(0..<1_000)
        )

        // A first position that cannot occur (with or without a
        // last position) is unsatisfiable before any last-position
        // logic runs.
        XCTAssertEqual(
            result("bytes=9223372036854775806-", 1_000),
            .unsatisfiable
        )
        XCTAssertEqual(
            result("bytes=1000-0", 1_000),
            .unsatisfiable
        )

        // A last position within Int range saturates at the
        // representation end and never overflows the upper bound.
        XCTAssertEqual(
            result("bytes=0-9223372036854775807", 1_000),
            .satisfiable(0..<1_000)
        )
        XCTAssertEqual(
            result("bytes=999-999", 1_000),
            .satisfiable(999..<1_000)
        )

        // Suffix zero is empty: treated as malformed so the
        // transport ignores the header instead of building a
        // zero-length 206.
        XCTAssertEqual(
            result("bytes=-0", 1_000),
            .malformed
        )

        // A zero-length representation is never satisfiable.
        XCTAssertEqual(
            result("bytes=0-", 0),
            .unsatisfiable
        )
        XCTAssertEqual(
            result("bytes=-5", 0),
            .unsatisfiable
        )
    }

    private func makeApp(
        region: FileRegion
    ) -> Application {
        let app = Application()

        app.get("/file") { request in
            switch request.byteRange(
                totalLength: region.readableBytes
            ) {
            case .satisfiable(let range):
                return .partialFileRegion(
                    region,
                    range: range,
                    contentType:
                        "application/octet-stream"
                )

            case .unsatisfiable:
                return .rangeNotSatisfiable(
                    totalLength:
                        region.readableBytes
                )

            case .none,
                 .malformed,
                 .unsupportedMultiple,
                 .unsupportedUnit:
                return Response
                    .fileRegion(
                        region,
                        contentType:
                            "application/octet-stream"
                    )
                    .acceptingByteRanges()
            }
        }

        return app
    }

    private func makeChannel(
        _ app: Application
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        return channel
    }

    private func sendRequest(
        method: NIOHTTP1.HTTPMethod,
        range: String,
        channel: EmbeddedChannel
    ) throws {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: "/file"
        )
        head.headers.add(
            name: "range",
            value: range
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }
}
