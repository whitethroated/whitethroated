import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ServerSentEventTests: XCTestCase {
    func testSSESerializesEventFieldsAndMultilineData() {
        let event = ServerSentEvent(
            data: "first\nsecond",
            event: "message",
            id: "42",
            retryMilliseconds: 1_000
        )

        XCTAssertEqual(
            event.serialized(),
            "event: message\n"
                + "id: 42\n"
                + "retry: 1000\n"
                + "data: first\n"
                + "data: second\n\n"
        )
    }

    func testSSEPreservesEmptyDataLines() {
        let event = ServerSentEvent(
            data: "one\n\ntwo"
        )

        XCTAssertEqual(
            event.serialized(),
            "data: one\n"
                + "data: \n"
                + "data: two\n\n"
        )
    }

    func testSSEResponseUsesExpectedHeadersAndWireBody() throws {
        let app = Application()

        app.get("/events") { _ in
            Response.sse { writer in
                writer.writeSSE(
                    ServerSentEvent(
                        data: "ready",
                        id: "1"
                    )
                )
            }
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/events"
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected SSE response head")
        }

        XCTAssertEqual(
            head.headers.first(
                name: "content-type"
            ),
            "text/event-stream; charset=utf-8"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "cache-control"
            ),
            "no-cache"
        )

        guard case .body(let data)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected SSE event body")
        }

        guard case .byteBuffer(let buffer) = data else {
            return XCTFail("Expected SSE ByteBuffer")
        }

        XCTAssertEqual(
            buffer.getString(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            ),
            "id: 1\ndata: ready\n\n"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected SSE response end")
        }
    }
}
