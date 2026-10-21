import NIOCore
import NIOEmbedded
import NIOHTTP1
import WhiteThroatedCompression
import XCTest
@testable import WhiteThroated

final class CompressionTransportTests: XCTestCase {
    private var largeText: String {
        String(
            repeating: "Hello, WhiteThroated! ",
            count: 64
        )
    }

    func testStockTransportCompressesNegotiatedResponse()
        throws
    {
        let app = makeApp()
        let text = largeText
        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try sendRequest(
            on: channel,
            encoding: "gzip"
        )

        let head = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertEqual(head.status, .ok)
        XCTAssertEqual(
            head.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
        XCTAssertTrue(
            varyContainsAcceptEncoding(
                head.headers
            )
        )

        let compressed = try XCTUnwrap(
            readBodyBytes(channel)
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            String(compressed.count)
        )
        XCTAssertEqual(
            inflateGzip(compressed),
            Array(text.utf8)
        )
        XCTAssertTrue(try readEnd(channel))
    }

    func testStockTransportServesIdentityWithVary()
        throws
    {
        let app = makeApp()
        let text = largeText
        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try sendRequest(
            on: channel,
            encoding: nil
        )

        let head = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertNil(
            head.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyContainsAcceptEncoding(
                head.headers
            )
        )

        let body = try XCTUnwrap(
            readBodyBytes(channel)
        )

        XCTAssertEqual(body, Array(text.utf8))
        XCTAssertTrue(try readEnd(channel))
    }

    func testStockTransportPipelinedRequestsKeepFraming()
        throws
    {
        let app = makeApp()
        let text = largeText
        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try writeRequest(
            on: channel,
            encoding: "gzip"
        )
        try writeRequest(
            on: channel,
            encoding: nil
        )
        channel.embeddedEventLoop.run()

        let firstHead = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertEqual(
            firstHead.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )

        let firstBody = try XCTUnwrap(
            readBodyBytes(channel)
        )

        XCTAssertTrue(try readEnd(channel))

        let secondHead = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertNil(
            secondHead.headers.first(
                name: "content-encoding"
            )
        )

        let secondBody = try XCTUnwrap(
            readBodyBytes(channel)
        )

        XCTAssertTrue(try readEnd(channel))
        XCTAssertEqual(
            inflateGzip(firstBody),
            Array(text.utf8)
        )
        XCTAssertEqual(
            secondBody,
            Array(text.utf8)
        )
    }

    func testStockTransportHeadKeepsCompressedLengthWithoutBody()
        throws
    {
        let app = makeApp()
        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try sendRequest(
            on: channel,
            encoding: "gzip",
            method: .HEAD
        )

        let head = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )

        let length = try XCTUnwrap(
            Int(
                head.headers.first(
                    name: "content-length"
                ) ?? ""
            )
        )

        XCTAssertGreaterThan(length, 0)

        guard case .end? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) else {
            return XCTFail(
                "Expected response end without a body"
            )
        }
    }

    func testStockTransportStreamingResponseIsNotCompressed()
        throws
    {
        let app = Application()
        let text = largeText

        app.use(compression: Compression())
        app.get("/events") { _ in
            Response.stream { writer in
                writer.writeAndFlush(
                    ByteBuffer(string: text)
                )
            }
        }

        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try sendRequest(
            on: channel,
            encoding: "gzip",
            uri: "/events"
        )
        channel.embeddedEventLoop.run()

        let head = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertNil(
            head.headers.first(
                name: "content-encoding"
            )
        )

        let body = try XCTUnwrap(
            readBodyBytes(channel)
        )

        XCTAssertEqual(body, Array(text.utf8))
        XCTAssertTrue(try readEnd(channel))
    }

    func testStockTransportStreamsCompressedChunks()
        throws
    {
        let app = makeStreamingApp(
            contentType: "text/plain"
        )
        let payload = streamChunks.joined()
        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try sendRequest(
            on: channel,
            encoding: "gzip",
            uri: "/stream"
        )
        settle(channel)

        let head = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertEqual(
            head.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
        XCTAssertNil(
            head.headers.first(
                name: "content-length"
            )
        )
        XCTAssertTrue(
            varyContainsAcceptEncoding(
                head.headers
            )
        )

        let compressed = try readBodyUntilEnd(
            channel
        )

        XCTAssertEqual(
            inflateGzip(compressed),
            Array(payload.utf8)
        )
    }

    func testStockTransportStreamsIdentityWithoutEncoding()
        throws
    {
        let app = makeStreamingApp(
            contentType: "text/plain"
        )
        let payload = streamChunks.joined()
        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try sendRequest(
            on: channel,
            encoding: nil,
            uri: "/stream"
        )
        settle(channel)

        let head = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertNil(
            head.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyContainsAcceptEncoding(
                head.headers
            )
        )

        let body = try readBodyUntilEnd(channel)

        XCTAssertEqual(body, Array(payload.utf8))
    }

    func testStockTransportStreamsIdentityForIneligibleType()
        throws
    {
        let app = makeStreamingApp(
            contentType: "image/png"
        )
        let payload = streamChunks.joined()
        let channel = try makeChannel(app)

        defer {
            _ = try? channel.finish()
        }

        try sendRequest(
            on: channel,
            encoding: "gzip",
            uri: "/stream"
        )
        settle(channel)

        let head = try XCTUnwrap(
            readResponseHead(channel)
        )

        XCTAssertNil(
            head.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertFalse(
            varyContainsAcceptEncoding(
                head.headers
            )
        )

        let body = try readBodyUntilEnd(channel)

        XCTAssertEqual(body, Array(payload.utf8))
    }

    // MARK: - Helpers

    private var streamChunks: [String] {
        ["alpha ", "beta ", "gamma"]
    }

    private func makeStreamingApp(
        contentType: String?
    ) -> Application {
        let app = Application()
        let compression = Compression()
        let chunks = streamChunks

        app.use(compression: compression)
        app.get("/stream") { request in
            compression.stream(
                for: request,
                contentType: contentType
            ) { writer in
                var last = writer.eventLoop
                    .makeSucceededVoidFuture()

                for chunk in chunks {
                    last = writer
                        .writeStringAndFlush(
                            chunk
                        )
                }

                return last
            }
        }

        return app
    }

    private func settle(
        _ channel: EmbeddedChannel
    ) {
        channel.embeddedEventLoop.run()
        channel.embeddedEventLoop.run()
    }

    private func readBodyUntilEnd(
        _ channel: EmbeddedChannel
    ) throws -> [UInt8] {
        var bytes: [UInt8] = []

        while
            let part = try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        {
            switch part {
            case .body(.byteBuffer(let buffer)):
                bytes.append(
                    contentsOf:
                        buffer.readableBytesView
                )

            case .end:
                return bytes

            case .head, .body:
                XCTFail("unexpected response part")
                return bytes
            }
        }

        XCTFail("response stream ended early")
        return bytes
    }

    private func makeApp() -> Application {
        let app = Application()
        let text = largeText

        app.use(compression: Compression())
        app.get("/report") { _ in
            Response.text(text)
        }

        return app
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

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        return channel
    }

    private func sendRequest(
        on channel: EmbeddedChannel,
        encoding: String?,
        method: NIOHTTP1.HTTPMethod = .GET,
        uri: String = "/report"
    ) throws {
        try writeRequest(
            on: channel,
            encoding: encoding,
            method: method,
            uri: uri
        )

        channel.embeddedEventLoop.run()
    }

    private func writeRequest(
        on channel: EmbeddedChannel,
        encoding: String?,
        method: NIOHTTP1.HTTPMethod = .GET,
        uri: String = "/report"
    ) throws {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: uri
        )

        if let encoding {
            head.headers.add(
                name: "accept-encoding",
                value: encoding
            )
        }

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }

    private func readResponseHead(
        _ channel: EmbeddedChannel
    ) throws -> HTTPResponseHead? {
        guard
            case .head(let head)? = try channel
                .readOutbound(
                    as: HTTPServerResponsePart.self
                )
        else {
            return nil
        }

        return head
    }

    private func readBodyBytes(
        _ channel: EmbeddedChannel
    ) throws -> [UInt8]? {
        guard
            case .body(.byteBuffer(let buffer))? = try channel
                .readOutbound(
                    as: HTTPServerResponsePart.self
                )
        else {
            return nil
        }

        return Array(buffer.readableBytesView)
    }

    private func readEnd(
        _ channel: EmbeddedChannel
    ) throws -> Bool {
        guard
            case .end? = try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return false
        }

        return true
    }
}
