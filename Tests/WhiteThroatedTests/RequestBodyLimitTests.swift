import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class RequestBodyLimitTests: XCTestCase {
    func testPayloadAtLimitIsAccepted() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 5
            )
        )

        app.post("/echo") { request in
            .text(request.bodyString ?? "")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        try writeRequest(
            body: "12345",
            to: channel
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

    func testPayloadOverLimitReturns413() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 4
            )
        )

        app.post("/echo") { request in
            .text(request.bodyString ?? "")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        try writeRequest(
            body: "12345",
            to: channel
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

    func testChunkedPayloadIsLimitedAcrossBodyParts() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 5
            )
        )

        app.post("/echo") { request in
            .text(request.bodyString ?? "")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/echo"
        )
        head.headers.add(
            name: "transfer-encoding",
            value: "chunked"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        var first = channel.allocator.buffer(capacity: 3)
        first.writeString("123")
        try channel.writeInbound(
            HTTPServerRequestPart.body(first)
        )

        var second = channel.allocator.buffer(capacity: 3)
        second.writeString("456")
        try channel.writeInbound(
            HTTPServerRequestPart.body(second)
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

    private func writeRequest(
        body: String,
        to channel: EmbeddedChannel
    ) throws {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/echo"
        )
        head.headers.add(
            name: "content-length",
            value: String(body.utf8.count)
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        var buffer = channel.allocator.buffer(
            capacity: body.utf8.count
        )
        buffer.writeString(body)

        try channel.writeInbound(
            HTTPServerRequestPart.body(buffer)
        )
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }
}
