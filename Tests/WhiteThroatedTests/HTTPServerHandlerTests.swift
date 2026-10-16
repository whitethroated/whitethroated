import XCTest
@testable import WhiteThroated
import NIOEmbedded
import NIOHTTP1

final class HTTPServerHandlerTests: XCTestCase {
    func testHeadResponseSuppressesBody() throws {
        let app = Application()

        app.get("/resource") { _ in
            .text("payload")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        var requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .HEAD,
            uri: "/resource"
        )
        requestHead.headers.add(
            name: "connection",
            value: "close"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(requestHead)
        )
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            responseHead.headers.first(name: "content-length"),
            "7"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "HEAD response must not emit a body part"
            )
        }
    }

    func testHTTP11KeepAliveDoesNotAddRedundantConnectionHeader() throws {
        let app = Application()

        app.get("/") { _ in
            .text("ok")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(requestHead)
        )
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertNil(
            responseHead.headers.first(name: "connection")
        )
        XCTAssertEqual(
            responseHead.version,
            .http1_1
        )
    }

    func testHTTP10KeepAliveIsEchoed() throws {
        let app = Application()

        app.get("/") { _ in
            .text("ok")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        var requestHead = HTTPRequestHead(
            version: .http1_0,
            method: .GET,
            uri: "/"
        )
        requestHead.headers.add(
            name: "connection",
            value: "keep-alive"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(requestHead)
        )
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            responseHead.headers.first(name: "connection"),
            "keep-alive"
        )
        XCTAssertEqual(
            responseHead.version,
            .http1_0
        )
    }

    func testNoContentSuppressesBodyAndContentLength() throws {
        let app = Application()

        app.get("/empty") { _ in
            Response(
                status: .noContent,
                headers: HTTPHeaders([
                    ("content-length", "4")
                ]),
                body: .text("oops")
            )
        }

        let channel = try makeChannel(app)

        try sendGet(
            "/empty",
            to: channel
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.status,
            .noContent
        )
        XCTAssertNil(
            head.headers.first(
                name: "content-length"
            )
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "204 must not emit a body"
            )
        }
    }

    func testNotModifiedPreservesExplicitLengthButSuppressesBody() throws {
        let app = Application()

        app.get("/cached") { _ in
            Response(
                status: .notModified,
                headers: HTTPHeaders([
                    ("content-length", "123")
                ]),
                body: .text("ignored")
            )
        }

        let channel = try makeChannel(app)

        try sendGet(
            "/cached",
            to: channel
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.status,
            .notModified
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "123"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "304 must not emit a body"
            )
        }
    }

    func testNoContentStreamDoesNotRunProducer() throws {
        let app = Application()
        let counter = ResponseStreamCounterForHandlerTests()

        app.get("/stream-empty") { _ in
            Response.stream(
                status: .noContent
            ) { writer in
                counter.calls += 1
                return writer.writeString("unexpected")
            }
        }

        let channel = try makeChannel(app)

        try sendGet(
            "/stream-empty",
            to: channel
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.status,
            .noContent
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "204 stream must end without body"
            )
        }

        XCTAssertEqual(
            counter.calls,
            0
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

    private func sendGet(
        _ uri: String,
        to channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: uri
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }
}

private final class ResponseStreamCounterForHandlerTests:
    @unchecked Sendable
{
    var calls = 0
}
