import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class DeclaredBodyLimitTests: XCTestCase {
    func testOversizedContentLengthReturns413WithoutBodyChunks() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 4
            )
        )

        app.post("/upload") { _ in
            .text("handled")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/upload"
        )
        head.headers.add(
            name: "content-length",
            value: "1024"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(head)
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
            responseHead.status,
            .payloadTooLarge
        )
    }

    func testOversizedDeclaredBodyChunksAreDiscarded() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 4
            )
        )

        app.post("/upload") { _ in
            .text("handled")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/upload"
        )
        head.headers.add(
            name: "content-length",
            value: "8"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        var body = channel.allocator.buffer(capacity: 8)
        body.writeString("12345678")

        try channel.writeInbound(
            HTTPServerRequestPart.body(body)
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
            responseHead.status,
            .payloadTooLarge
        )
    }

    func testGetHotPathDoesNotRequireContentLength() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 0
            )
        )

        app.get(
            "/health",
            response: .text("ok")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/health"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(head)
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

        XCTAssertEqual(responseHead.status, .ok)
    }
}
