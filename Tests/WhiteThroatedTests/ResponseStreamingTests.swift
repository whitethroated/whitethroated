import Foundation
import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class ResponseStreamCounter: @unchecked Sendable {
    var producerCalls = 0
    var errorCalls = 0
}

final class ResponseStreamingTests: XCTestCase {
    func testBufferedWriteFutureDoesNotDependOnFrameworkFinalFlush() throws {
        let app = Application()
        let counter = ResponseStreamCounter()

        app.get("/stream") { _ in
            Response.stream { writer in
                writer.writeString("a").flatMap {
                    counter.producerCalls += 1
                    return writer.writeString("b")
                }
            }
        }

        let channel = try makeChannel(app)

        try sendRequest(
            method: .GET,
            channel: channel
        )

        XCTAssertEqual(
            counter.producerCalls,
            1
        )

        guard case .head? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        var body = ""

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
                        "Expected ByteBuffer body"
                    )
                }

                body += buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ) ?? ""

            case .end:
                XCTAssertEqual(body, "ab")
                return
            }
        }

        XCTFail("Expected response end")
    }

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

    func testHTTP11UnknownLengthStreamUsesChunkedWireFraming() throws {
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

        let channel = try makeEncodedChannel(app)

        try sendRequest(
            method: .GET,
            channel: channel
        )

        let wire = try readEncodedResponse(
            from: channel
        )
        let lowercased = wire.lowercased()

        XCTAssertTrue(
            lowercased.contains(
                "transfer-encoding: chunked"
            )
        )
        XCTAssertFalse(
            lowercased.contains(
                "content-length:"
            )
        )
        XCTAssertTrue(
            wire.contains(
                "\r\n5\r\nhello\r\n"
            )
        )
        XCTAssertTrue(
            wire.contains(
                "\r\n6\r\n world\r\n"
            )
        )
        XCTAssertTrue(
            wire.hasSuffix(
                "0\r\n\r\n"
            )
        )
    }

    func testStreamContentLengthParameterSetsHeader() {
        let response = Response.stream(
            contentType: "text/plain",
            contentLength: 5
        ) { writer in
            writer.writeString("hello")
        }

        XCTAssertEqual(
            response.headers.first(
                name: "content-length"
            ),
            "5"
        )
    }

    func testHTTP11KnownLengthStreamAvoidsChunkedWireFraming() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response.stream(
                contentType: "text/plain",
                contentLength: 11
            ) { writer in
                writer.writeString("hello").flatMap {
                    writer.writeString(" world")
                }
            }
        }

        let channel = try makeEncodedChannel(app)

        try sendRequest(
            method: .GET,
            channel: channel
        )

        let wire = try readEncodedResponse(
            from: channel
        )
        let lowercased = wire.lowercased()

        XCTAssertTrue(
            lowercased.contains(
                "content-length: 11"
            )
        )
        XCTAssertFalse(
            lowercased.contains(
                "transfer-encoding:"
            )
        )
        XCTAssertTrue(
            wire.hasSuffix(
                "\r\n\r\nhello world"
            )
        )
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

    func testFailedStreamProducerInvokesErrorCleanupOnce() throws {
        enum ProducerError: Error {
            case failed
        }

        let app = Application()
        let loop = EmbeddedEventLoop()
        let counter = ResponseStreamCounter()

        app.get("/stream") { _ in
            Response.stream(
                onError: { error in
                    if error is ProducerError {
                        counter.errorCalls += 1
                    }
                }
            ) { writer in
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

        XCTAssertEqual(
            counter.errorCalls,
            1
        )
        XCTAssertFalse(channel.isActive)
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

    func testClientCloseDoesNotWriteStreamEndAfterProducerCompletes() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/stream") { _ in
            Response.stream { writer in
                writer.writeStringAndFlush(
                    "event"
                ).flatMap {
                    writer.closeFuture
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
            return XCTFail("Expected streamed body")
        }

        try channel.close().wait()
        loop.run()

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
        XCTAssertFalse(channel.isActive)
    }

    func testResponseStreamCanWriteFileRegionChunk() throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString
            )

        try Data("file".utf8).write(
            to: url
        )

        let handle = try NIOFileHandle(
            _deprecatedPath: url.path
        )

        defer {
            try? handle.close()
            try? FileManager.default
                .removeItem(at: url)
        }

        let region = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 4
        )

        let app = Application()

        app.get("/stream") { _ in
            Response
                .stream(
                    contentType: "application/octet-stream"
                ) { writer in
                    writer.writeFileRegion(region)
                }
                .header(
                    "content-length",
                    "4"
                )
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

        guard case .fileRegion(let writtenRegion) = data else {
            return XCTFail(
                "Expected streamed IOData.fileRegion"
            )
        }

        XCTAssertEqual(
            writtenRegion.readableBytes,
            4
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response end")
        }
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

    private func makeEncodedChannel(
        _ app: Application
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPResponseEncoder()
            )
        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        return channel
    }

    private func readEncodedResponse(
        from channel: EmbeddedChannel
    ) throws -> String {
        var buffer = channel.allocator.buffer(
            capacity: 256
        )

        while let data = try channel.readOutbound(
            as: IOData.self
        ) {
            switch data {
            case .byteBuffer(var part):
                buffer.writeBuffer(&part)

            case .fileRegion:
                XCTFail(
                    "Unexpected FileRegion in encoded response"
                )
            }
        }

        return buffer.getString(
            at: buffer.readerIndex,
            length: buffer.readableBytes
        ) ?? ""
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
        channel.embeddedEventLoop.run()
    }
}
