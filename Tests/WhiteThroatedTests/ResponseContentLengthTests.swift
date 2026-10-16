import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ResponseContentLengthTests: XCTestCase {
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

    func testPreparedEmptyNormalizesContentLengthToZero() {
        let prepared = PreparedResponse
            .empty()
            .header(
                "Content-Length",
                "999"
            )

        XCTAssertEqual(
            prepared.http11Head.headers.first(
                name: "content-length"
            ),
            "0"
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
