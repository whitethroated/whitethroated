import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class ProtocolRouteCounter:
    @unchecked Sendable
{
    var hits = 0
}

final class HTTPProtocolValidationTests: XCTestCase {
    func testContentLengthTransferEncodingSmugglingIsRejectedBeforeHudhud()
        throws
    {
        let counter = ProtocolRouteCounter()
        let app = Application()

        app.post("/upload") { _ in
            counter.hits += 1
            return .text("unexpected")
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .configureHTTPServerPipeline(
                withPipeliningAssistance: true,
                withErrorHandling: true
            )

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        var bytes = channel.allocator.buffer(
            capacity: 256
        )
        bytes.writeString(
            "POST /upload HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Content-Length: 1\r\n"
                + "Transfer-Encoding: gzip, chunked\r\n"
                + "\r\n"
                + "3\r\na=1\r\n"
                + "0\r\n\r\n"
        )

        do {
            _ = try channel.writeInbound(bytes)
        } catch {
            // SwiftNIO may surface the parser error to the
            // EmbeddedChannel after its protocol error handler
            // has already written the 400 response.
        }

        channel.embeddedEventLoop.run()

        XCTAssertEqual(
            counter.hits,
            0
        )

        let response = try readOutboundText(
            from: channel
        )

        XCTAssertTrue(
            response.hasPrefix(
                "HTTP/1.1 400 Bad Request\r\n"
            )
        )
        XCTAssertTrue(
            response.contains(
                "Connection: close\r\n"
            )
        )
    }

    func testInvalidDuplicateContentLengthIsRejectedBeforeHudhud()
        throws
    {
        let counter = ProtocolRouteCounter()
        let app = Application()

        app.post("/upload") { _ in
            counter.hits += 1
            return .text("unexpected")
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .configureHTTPServerPipeline(
                withPipeliningAssistance: true,
                withErrorHandling: true
            )

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        var bytes = channel.allocator.buffer(
            capacity: 192
        )
        bytes.writeString(
            "POST /upload HTTP/1.1\r\n"
                + "Host: localhost\r\n"
                + "Content-Length: 4, 4\r\n"
                + "\r\n"
                + "test"
        )

        do {
            _ = try channel.writeInbound(bytes)
        } catch {
            // Expected parser failure on the embedded pipeline.
        }

        channel.embeddedEventLoop.run()

        XCTAssertEqual(
            counter.hits,
            0
        )

        let response = try readOutboundText(
            from: channel
        )

        XCTAssertTrue(
            response.hasPrefix(
                "HTTP/1.1 400 Bad Request\r\n"
            )
        )
    }

    private func readOutboundText(
        from channel: EmbeddedChannel
    ) throws -> String {
        var result = ""

        while let buffer = try channel.readOutbound(
            as: ByteBuffer.self
        ) {
            result += buffer.getString(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            ) ?? ""
        }

        return result
    }
}
