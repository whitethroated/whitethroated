import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ResponseContentLengthTests: XCTestCase {
    func testKnownBodyFactoriesSeedContentLength() {
        XCTAssertEqual(
            Response
                .text("hello")
                .headers
                .first(name: "content-length"),
            "5"
        )

        XCTAssertEqual(
            Response
                .bytes([1, 2, 3])
                .headers
                .first(name: "content-length"),
            "3"
        )

        var buffer =
            ByteBufferAllocator().buffer(
                capacity: 2
            )
        buffer.writeString("ok")

        XCTAssertEqual(
            Response
                .buffer(buffer)
                .headers
                .first(name: "content-length"),
            "2"
        )
    }

    func testNonLengthHeaderHelpersPreserveNormalizedFraming() {
        var response = Response.text("hello")

        XCTAssertTrue(
            response.contentLengthIsNormalized
        )

        response.setHeader(
            "date",
            "Thu, 01 Jan 1970 00:00:00 GMT"
        )

        XCTAssertTrue(
            response.contentLengthIsNormalized
        )

        response.appendHeader(
            "x-benchmark",
            "1"
        )

        XCTAssertTrue(
            response.contentLengthIsNormalized
        )

        response.setHeader(
            "content-length",
            "5"
        )

        XCTAssertFalse(
            response.contentLengthIsNormalized
        )
    }

    func testWriterRepairsLengthAfterDirectHeaderMutation() throws {
        let app = Application()

        app.get("/header-mutated") { _ in
            var response = Response.text("hello")
            response.headers.replaceOrAdd(
                name: "content-length",
                value: "999"
            )
            return response
        }

        let channel = try makeChannel(app)

        try send(
            method: .GET,
            uri: "/header-mutated",
            channel: channel
        )

        let head = try readHead(
            from: channel
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "5"
        )
    }

    func testWriterRepairsLengthAfterBodyMutation() throws {
        let app = Application()

        app.get("/mutated") { _ in
            var response = Response.text("hello")
            response.body = .text("longer")
            return response
        }

        let channel = try makeChannel(app)

        try send(
            method: .GET,
            uri: "/mutated",
            channel: channel
        )

        let head = try readHead(
            from: channel
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "6"
        )
    }

    func testWriterCollapsesDuplicateContentLength() throws {
        let app = Application()

        app.get("/duplicate") { _ in
            var response = Response.text("hello")
            response.headers.add(
                name: "Content-Length",
                value: "5"
            )
            return response
        }

        let channel = try makeChannel(app)

        try send(
            method: .GET,
            uri: "/duplicate",
            channel: channel
        )

        let head = try readHead(
            from: channel
        )

        XCTAssertEqual(
            head.headers[
                canonicalForm:
                    "content-length"
            ].map(String.init),
            ["5"]
        )
    }

    func testOrdinaryTextResponseOverridesIncorrectContentLength()
        throws
    {
        let app = Application()

        app.get("/text") { _ in
            Response
                .text("hello")
                .header(
                    "content-length",
                    "999"
                )
        }

        let channel = try makeChannel(app)

        try send(
            method: .GET,
            uri: "/text",
            channel: channel
        )

        let head = try readHead(
            from: channel
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "5"
        )

        guard case .body(
            .byteBuffer(let body)
        )? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        )
        else {
            return XCTFail(
                "Expected text body"
            )
        }

        XCTAssertEqual(
            body.getString(
                at: body.readerIndex,
                length: body.readableBytes
            ),
            "hello"
        )
    }

    func testOrdinaryEmptyResponseNormalizesLengthToZero()
        throws
    {
        let app = Application()

        app.get("/empty") { _ in
            Response
                .empty()
                .header(
                    "content-length",
                    "100"
                )
        }

        let channel = try makeChannel(app)

        try send(
            method: .GET,
            uri: "/empty",
            channel: channel
        )

        let head = try readHead(
            from: channel
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "0"
        )
    }

    func testHeadUsesRepresentationBodyLengthAndSuppressesBody()
        throws
    {
        let app = Application()

        app.get("/text") { _ in
            Response
                .text("hello")
                .header(
                    "content-length",
                    "999"
                )
        }

        let channel = try makeChannel(app)

        try send(
            method: .HEAD,
            uri: "/text",
            channel: channel
        )

        let head = try readHead(
            from: channel
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "5"
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

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
    }

    func testPreparedHeaderCannotDesynchronizeCachedLength() {
        let prepared = PreparedResponse
            .text("hello")
            .header(
                "content-length",
                "999"
            )

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "5"
        )
        XCTAssertEqual(
            prepared.response.headers.first(
                name: "content-length"
            ),
            "5"
        )
    }

    func testPreparedNoContentRemovesContentLength() {
        let prepared = PreparedResponse
            .empty()
            .header(
                "Content-Length",
                "999"
            )

        XCTAssertNil(
            prepared.http11Head.headers.first(
                name: "content-length"
            )
        )
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

    private func send(
        method: NIOHTTP1.HTTPMethod,
        uri: String,
        channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: method,
                    uri: uri
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }

    private func readHead(
        from channel: EmbeddedChannel
    ) throws -> HTTPResponseHead {
        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            throw ContentLengthTestError.missingHead
        }

        return head
    }
}

private enum ContentLengthTestError: Error {
    case missingHead
}
