import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class ResponseStreamCounter: @unchecked Sendable {
    var producerCalls = 0
}

final class ResponseStreamingTests: XCTestCase {
    func testResponseStreamWritesChunksAndFrameworkEndsResponse() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response.stream(
                contentType: "text/plain"
            ) { writer in
                writer.writeString("hello").flatMap {
                    writer.writeString(" world")
                }
            }
        }

        let channel = try makeChannel(app)

        try sendRequest(
            method: .GET,
            channel: channel
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.headers.first(
                name: "content-type"
            ),
            "text/plain"
        )
        XCTAssertNil(
            head.headers.first(
                name: "content-length"
            )
        )

        var values: [String] = []

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                return XCTFail(
                    "Unexpected second response head"
                )

            case .body(let data):
                guard case .byteBuffer(let buffer) = data else {
                    return XCTFail(
                        "Expected ByteBuffer stream chunk"
                    )
                }

                values.append(
                    buffer.getString(
                        at: buffer.readerIndex,
                        length: buffer.readableBytes
                    ) ?? ""
                )

            case .end:
                XCTAssertEqual(
                    values,
                    ["hello", " world"]
                )
                return
            }
        }

        XCTFail("Expected response end")
    }

    func testHeadSuppressesResponseStreamProducer() throws {
        let app = Application()
        let counter = ResponseStreamCounter()

        app.get("/stream") { _ in
            Response.stream(
                contentType: "text/plain"
            ) { writer in
                counter.producerCalls += 1
                return writer.writeString("body")
            }
        }

        let channel = try makeChannel(app)

        try sendRequest(
            method: .HEAD,
            channel: channel
        )

        guard case .head? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "HEAD stream response must end without body"
            )
        }

        XCTAssertEqual(
            counter.producerCalls,
            0
        )
    }

    func testHTTP10StreamWithoutLengthForcesConnectionClose() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response.stream { writer in
                writer.writeString("body")
            }
        }

        let channel = try makeChannel(app)

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_0,
                    method: .GET,
                    uri: "/stream",
                    headers: HTTPHeaders([
                        ("connection", "keep-alive")
                    ])
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
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.headers.first(
                name: "connection"
            ),
            "close"
        )

        guard case .body? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response body")
        }

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response end")
        }
    }

    func testHTTP10StreamWithExplicitLengthCanKeepAlive() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response
                .stream { writer in
                    writer.writeString("body")
                }
                .header(
                    "content-length",
                    "4"
                )
        }

        let channel = try makeChannel(app)

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_0,
                    method: .GET,
                    uri: "/stream",
                    headers: HTTPHeaders([
                        ("connection", "keep-alive")
                    ])
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
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.headers.first(
                name: "connection"
            ),
            "keep-alive"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "4"
        )

        guard case .body? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response body")
        }

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response end")
        }
    }

    func testFailedStreamProducerClosesConnectionWithoutEnd() throws {
        enum ProducerError: Error {
            case failed
        }

        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/stream") { _ in
            Response.stream { writer in
                writer.writeString("partial").flatMap {
                    writer.eventLoop.makeFailedFuture(
                        ProducerError.failed
                    )
                }
            }
        }

        let channel = EmbeddedChannel(
            loop: loop
        )
        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try sendRequest(
            method: .GET,
            channel: channel
        )
        loop.run()

        guard case .head? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        guard case .body? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected partial response body")
        }

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
        XCTAssertFalse(channel.isActive)
    }

    func testStreamProducerCanFlushIndividualChunk() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response.stream { writer in
                writer.writeStringAndFlush("event")
            }
        }

        let channel = try makeChannel(app)

        try sendRequest(
            method: .GET,
            channel: channel
        )

        guard case .head? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        guard case .body(let data)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response body")
        }

        guard case .byteBuffer(let buffer) = data else {
            return XCTFail("Expected ByteBuffer body")
        }

        XCTAssertEqual(
            buffer.getString(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            ),
            "event"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response end")
        }
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

    private func sendRequest(
        method: NIOHTTP1.HTTPMethod,
        channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: method,
                    uri: "/stream"
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }
}
