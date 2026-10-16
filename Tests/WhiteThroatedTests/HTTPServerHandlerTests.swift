import XCTest
@testable import WhiteThroated
import NIOCore
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

    func testHTTP11KeepAliveLeavesChannelActive() throws {
        let app = Application()

        app.get("/") { _ in
            .text("ok")
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try activateHTTPTestChannel(channel)

        try sendGet(
            "/",
            to: channel
        )
        channel.embeddedEventLoop.run()

        XCTAssertTrue(channel.isActive)
    }

    func testHTTP11ConnectionCloseClosesAfterResponseEnd() throws {
        let app = Application()

        app.get("/") { _ in
            .text("ok")
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try activateHTTPTestChannel(channel)

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/"
        )
        head.headers.add(
            name: "connection",
            value: "close"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        channel.embeddedEventLoop.run()

        guard case .head? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response head"
            )
        }

        guard case .body? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response body"
            )
        }

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response end"
            )
        }

        XCTAssertFalse(channel.isActive)
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

    func testPreparedRouteDoesNotBypassMiddleware() throws {
        let app = Application()

        app.useFast { _, _, _ in
            .response(
                .text(
                    "blocked",
                    status: .unauthorized
                )
            )
        }

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = try makeChannel(app)

        try sendGet(
            "/prepared",
            to: channel
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
            .unauthorized
        )
    }

    func testSequentialRequestsDoNotLeakAggregatedBodyState() throws {
        let app = Application()

        app.post("/size") { request in
            .text(
                String(request.body.readableBytes)
            )
        }

        let channel = try makeChannel(app)

        try sendRequest(
            method: .POST,
            uri: "/size",
            body: "abc",
            to: channel
        )
        XCTAssertEqual(
            try readTextResponse(from: channel),
            "3"
        )

        try sendRequest(
            method: .POST,
            uri: "/size",
            body: "x",
            to: channel
        )
        XCTAssertEqual(
            try readTextResponse(from: channel),
            "1"
        )
    }

    func testSequentialRequestAfterPayloadTooLargeUsesCleanState() throws {
        let app = Application()

        app.post("/size") { request in
            .text(
                String(request.body.readableBytes)
            )
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app,
                    maxRequestBodyBytes: 3
                )
            )

        var oversizedHead = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/size"
        )
        oversizedHead.headers.add(
            name: "content-length",
            value: "4"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                oversizedHead
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(
                ByteBuffer(
                    string: "abcd"
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let oversizedResponse)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected oversized response head"
            )
        }

        XCTAssertEqual(
            oversizedResponse.status,
            .payloadTooLarge
        )

        while let _ = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {}

        try sendRequest(
            method: .POST,
            uri: "/size",
            body: "ok",
            to: channel
        )
        XCTAssertEqual(
            try readTextResponse(from: channel),
            "2"
        )
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
        try sendRequest(
            method: .GET,
            uri: uri,
            to: channel
        )
    }

    private func sendRequest(
        method: NIOHTTP1.HTTPMethod,
        uri: String,
        body: String? = nil,
        to channel: EmbeddedChannel
    ) throws {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: uri
        )

        if let body {
            head.headers.add(
                name: "content-length",
                value: String(body.utf8.count)
            )
        }

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        if let body {
            _ = try channel.writeInbound(
                HTTPServerRequestPart.body(
                    ByteBuffer(string: body)
                )
            )
        }

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }

    private func readTextResponse(
        from channel: EmbeddedChannel
    ) throws -> String {
        guard case .head? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            throw HTTPServerHandlerTestError
                .missingHead
        }

        var body = ""

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                throw HTTPServerHandlerTestError
                    .unexpectedHead

            case .body(let data):
                switch data {
                case .byteBuffer(let buffer):
                    body +=
                        buffer.getString(
                            at: buffer.readerIndex,
                            length: buffer.readableBytes
                        ) ?? ""

                case .fileRegion:
                    throw HTTPServerHandlerTestError
                        .unexpectedFileRegion
                }

            case .end:
                return body
            }
        }

        throw HTTPServerHandlerTestError
            .missingEnd
    }
}

private enum HTTPServerHandlerTestError: Error {
    case missingHead
    case unexpectedHead
    case unexpectedFileRegion
    case missingEnd
}

private final class ResponseStreamCounterForHandlerTests:
    @unchecked Sendable
{
    var calls = 0
}
