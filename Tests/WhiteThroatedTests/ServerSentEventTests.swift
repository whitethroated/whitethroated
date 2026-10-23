import XCTest
@testable import WhiteThroated
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

    func testSSENormalizesCRLFAndLoneCRInSinglePass() {
        let event = ServerSentEvent(
            data: "one\r\ntwo\rthree\n"
        )

        XCTAssertEqual(
            event.serialized(),
            "data: one\n"
                + "data: two\n"
                + "data: three\n"
                + "data: \n\n"
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

    func testSSEMutatedEventFieldCannotInjectOtherFields() {
        // Fields stay mutable after construction, so the writer must
        // not rely on initializer-time checks. A line break inside a
        // header field is emitted one labeled line at a time instead
        // of forging other field lines.
        var event = ServerSentEvent(
            data: "ok",
            event: "greeting"
        )
        event.event = "greeting\r\nid: forged-id"

        XCTAssertEqual(
            event.serialized(),
            "event: greeting\n"
                + "event: id: forged-id\n"
                + "data: ok\n\n"
        )
    }

    func testSSEMutatedIDFieldCannotInjectOtherFields() {
        var event = ServerSentEvent(
            data: "ok",
            id: "1"
        )
        event.id = "1\nretry: forged-retry"

        XCTAssertEqual(
            event.serialized(),
            "id: 1\n"
                + "id: retry: forged-retry\n"
                + "data: ok\n\n"
        )
    }

    func testStreamWriterCreatesChannelAllocatorBuffer() throws {
        let app = Application()

        app.get("/buffer") { _ in
            Response.stream { writer in
                var buffer = writer.makeBuffer(
                    capacity: 16
                )
                buffer.writeString("allocated")
                return writer.write(buffer)
            }
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try activateHTTPTestChannel(channel)

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/buffer"
                )
            )
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

        guard case .body(let data)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            ),
            case .byteBuffer(let buffer) = data
        else {
            return XCTFail(
                "Expected response ByteBuffer"
            )
        }

        XCTAssertEqual(
            buffer.getString(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            ),
            "allocated"
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

        try activateHTTPTestChannel(channel)

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
        channel.embeddedEventLoop.run()

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
