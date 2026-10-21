import CZlib
import NIOCore
import NIOHTTP1
import XCTest
@testable import WhiteThroated
@testable import WhiteThroatedCompression

final class StreamingCompressionTests: XCTestCase {
    private func makeRequest(
        encoding: String? = nil
    ) -> Request {
        var headers = HTTPHeaders()

        if let encoding {
            headers.add(
                name: "accept-encoding",
                value: encoding
            )
        }

        return Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/stream",
                headers: headers
            ),
            body:
                ByteBufferAllocator()
                    .buffer(capacity: 0)
        )
    }

    func testDeflateStreamRoundTripsAcrossWrites()
        throws
    {
        let deflater = try XCTUnwrap(
            ZlibDeflateStream(level: 6)
        )

        let chunks = [
            "first chunk ",
            "second chunk ",
            String(repeating: "x", count: 5_000),
        ]

        var compressed: [UInt8] = []

        for chunk in chunks {
            let output = try XCTUnwrap(
                deflater.encode(
                    ByteBuffer(string: chunk),
                    flush: Z_NO_FLUSH
                )
            )

            compressed.append(
                contentsOf: output.readableBytesView
            )
        }

        let tail = try XCTUnwrap(deflater.finish())

        compressed.append(
            contentsOf: tail.readableBytesView
        )

        XCTAssertEqual(
            inflateGzip(compressed),
            Array(chunks.joined().utf8)
        )
    }

    func testSyncFlushBoundariesAreIndependentlyDecodable()
        throws
    {
        let deflater = try XCTUnwrap(
            ZlibDeflateStream(level: 6)
        )

        let first = try XCTUnwrap(
            deflater.encode(
                ByteBuffer(string: "event: one\n\n"),
                flush: Z_SYNC_FLUSH
            )
        )
        let firstBytes = Array(
            first.readableBytesView
        )

        XCTAssertEqual(
            inflateGzipPartial(firstBytes),
            Array("event: one\n\n".utf8)
        )

        let second = try XCTUnwrap(
            deflater.encode(
                ByteBuffer(string: "event: two\n\n"),
                flush: Z_SYNC_FLUSH
            )
        )

        var all = firstBytes
        all.append(
            contentsOf: second.readableBytesView
        )

        XCTAssertEqual(
            inflateGzipPartial(all),
            Array(
                "event: one\n\nevent: two\n\n"
                    .utf8
            )
        )

        let tail = try XCTUnwrap(deflater.finish())

        all.append(
            contentsOf: tail.readableBytesView
        )

        XCTAssertEqual(
            inflateGzip(all),
            Array(
                "event: one\n\nevent: two\n\n"
                    .utf8
            )
        )
    }

    func testFinishWithoutWritesProducesValidMember()
        throws
    {
        let deflater = try XCTUnwrap(
            ZlibDeflateStream(level: 6)
        )
        let tail = try XCTUnwrap(deflater.finish())

        XCTAssertEqual(
            inflateGzip(Array(tail.readableBytesView)),
            []
        )
    }

    func testStreamResponseDeclaresGzipWhenNegotiated() {
        let compression = Compression()

        let response = compression.stream(
            for: makeRequest(encoding: "gzip"),
            contentType: "text/plain"
        ) { writer in
            writer.writeStringAndFlush("chunk")
        }

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
        XCTAssertTrue(
            varyContainsAcceptEncoding(
                response.headers
            )
        )

        if case .stream = response.body {
        } else {
            XCTFail("expected stream body")
        }
    }

    func testStreamResponseIdentityWithoutAcceptEncoding() {
        let compression = Compression()

        let response = compression.stream(
            for: makeRequest(),
            contentType: "text/plain"
        ) { writer in
            writer.writeStringAndFlush("chunk")
        }

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyContainsAcceptEncoding(
                response.headers
            )
        )
    }

    func testStreamResponseDeniedIdentityServesIdentity() {
        let compression = Compression()

        let response = compression.stream(
            for: makeRequest(
                encoding: "identity;q=0"
            ),
            contentType: "text/plain"
        ) { writer in
            writer.writeStringAndFlush("chunk")
        }

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyContainsAcceptEncoding(
                response.headers
            )
        )
    }

    func testStreamResponseIneligibleContentType() {
        let compression = Compression()

        let response = compression.stream(
            for: makeRequest(encoding: "gzip"),
            contentType: "image/png"
        ) { writer in
            writer.writeStringAndFlush("chunk")
        }

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertFalse(
            varyContainsAcceptEncoding(
                response.headers
            )
        )
    }

    func testStreamResponseWithoutContentType() {
        let compression = Compression()

        let response = compression.stream(
            for: makeRequest(encoding: "gzip")
        ) { writer in
            writer.writeStringAndFlush("chunk")
        }

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertFalse(
            varyContainsAcceptEncoding(
                response.headers
            )
        )
    }

    func testStreamResponseAllowsAllPolicy() {
        let compression = Compression(
            configuration:
                Compression.Configuration(
                    contentTypes: .allowAll
                )
        )

        let response = compression.stream(
            for: makeRequest(encoding: "gzip"),
            contentType: "application/octet-stream"
        ) { writer in
            writer.writeStringAndFlush("chunk")
        }

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }
}
