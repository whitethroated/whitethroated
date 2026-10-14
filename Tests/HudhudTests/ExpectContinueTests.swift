import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ExpectContinueTests: XCTestCase {
    func testAcceptableRequestGets100ContinueBeforeBody() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 16
            )
        )

        app.post("/upload") { request in
            .text(
                String(request.body.readableBytes)
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead()
        head.headers.add(
            name: "expect",
            value: "100-continue"
        )
        head.headers.add(
            name: "content-length",
            value: "3"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let informational)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected informational response head"
            )
        }

        XCTAssertEqual(
            informational.status,
            .continue
        )

        var body = channel.allocator.buffer(
            capacity: 3
        )
        body.writeString("abc")

        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(body)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        let response = try readFinalResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            "3"
        )
    }

    func testOversizedExpectedRequestGets413Without100Continue() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 4
            )
        )

        app.post("/upload") { _ in
            .text("unexpected")
        }

        let channel = try makeChannel(app)
        var head = makeHead()
        head.headers.add(
            name: "expect",
            value: "100-continue"
        )
        head.headers.add(
            name: "content-length",
            value: "8"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        let response = try readFinalResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
    }

    func testHugeDeclaredLengthGets413Without100Continue() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 4
            )
        )

        app.post("/upload") { _ in
            .text("unexpected")
        }

        let channel = try makeChannel(app)
        var head = makeHead()
        head.headers.add(
            name: "expect",
            value: "100-continue"
        )
        head.headers.add(
            name: "content-length",
            value:
                "999999999999999999999999999999999999"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        let response = try readFinalResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
    }

    func testContentLengthAtLimitStillGets100Continue() throws {
        let app = Application(
            configuration: ServerConfiguration(
                maxRequestBodyBytes: 4
            )
        )

        app.post("/upload") { request in
            .text(
                String(request.body.readableBytes)
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead()
        head.headers.add(
            name: "expect",
            value: "100-continue"
        )
        head.headers.add(
            name: "content-length",
            value: "0004"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let informational)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected informational response head"
            )
        }

        XCTAssertEqual(
            informational.status,
            .continue
        )
    }

    func testHugeStreamingDeclaredLengthGets413WithoutConsumer()
        throws
    {
        final class ConsumerCounter:
            @unchecked Sendable
        {
            var calls = 0
        }

        let app = Application()
        let counter = ConsumerCounter()

        app.postStream(
            "/upload",
            maxBodyBytes: 4
        ) { _, _ in
            counter.calls += 1

            return BodyStreamConsumer(
                onChunk: { _ in },
                onEnd: {
                    .text("unexpected")
                }
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead()
        head.headers.add(
            name: "expect",
            value: "100-continue"
        )
        head.headers.add(
            name: "content-length",
            value:
                "999999999999999999999999999999999999"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        let response = try readFinalResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
        XCTAssertEqual(
            counter.calls,
            0
        )
    }

    func testUnsupportedExpectationGets417() throws {
        let app = Application()
        app.post("/upload") { _ in
            .text("unexpected")
        }

        let channel = try makeChannel(app)
        var head = makeHead()
        head.headers.add(
            name: "expect",
            value: "something-else"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        let response = try readFinalResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .expectationFailed
        )
    }

    func testStreamingRouteGets100Continue() throws {
        let app = Application()

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { _ in nil },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .noContent()
                    )
                }
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead()
        head.headers.add(
            name: "expect",
            value: "100-continue"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let informational)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected informational response head"
            )
        }

        XCTAssertEqual(
            informational.status,
            .continue
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        let response = try readFinalResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .noContent
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

    private func makeHead() -> HTTPRequestHead {
        HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/upload"
        )
    }

    private func readFinalResponse(
        from channel: EmbeddedChannel
    ) throws -> (
        head: HTTPResponseHead,
        body: String
    ) {
        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            throw ExpectTestError.missingHead
        }

        var body = ""

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                throw ExpectTestError.unexpectedHead

            case .body(let data):
                guard case .byteBuffer(let buffer) = data else {
                    throw ExpectTestError.unexpectedBody
                }

                body += buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ) ?? ""

            case .end:
                return (head, body)
            }
        }

        throw ExpectTestError.missingEnd
    }
}

private enum ExpectTestError: Error {
    case missingHead
    case missingEnd
    case unexpectedHead
    case unexpectedBody
}
