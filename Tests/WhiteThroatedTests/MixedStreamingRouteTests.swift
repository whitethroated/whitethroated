import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class MixedStreamingRouteTests: XCTestCase {
    func testOrdinaryGetIgnoresUnrelatedPostStreamingState() throws {
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

        app.get(
            "/prepared",
            response: .text("ok")
        )

        let channel = try makeChannel(app)

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/prepared"
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            "ok"
        )
    }

    func testOrdinaryRouteSharesMethodWithStreamingRoute() throws {
        let app = Application()

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { _ in nil },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("stream")
                    )
                }
            )
        }

        app.post("/regular") { request in
            .text(
                String(request.body.readableBytes)
            )
        }

        let channel = try makeChannel(app)

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/regular"
        )
        head.headers.add(
            name: "content-length",
            value: "5"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        var body = channel.allocator.buffer(
            capacity: 5
        )
        body.writeString("hello")

        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(body)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            "5"
        )
    }

    func testNotFoundSharesMethodWithStreamingRoute() throws {
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

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .POST,
                    uri: "/missing"
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .notFound
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

    private func readResponse(
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
            throw MixedRouteTestError.missingHead
        }

        var body = ""

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                throw MixedRouteTestError.unexpectedHead

            case .body(let data):
                guard case .byteBuffer(let buffer) = data else {
                    throw MixedRouteTestError.unexpectedBody
                }

                body += buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ) ?? ""

            case .end:
                return (head, body)
            }
        }

        throw MixedRouteTestError.missingEnd
    }
}

private enum MixedRouteTestError: Error {
    case missingHead
    case missingEnd
    case unexpectedHead
    case unexpectedBody
}
