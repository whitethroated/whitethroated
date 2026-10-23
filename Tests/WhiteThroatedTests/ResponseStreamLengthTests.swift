import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class StreamLengthErrorBox:
    @unchecked Sendable
{
    var error: ResponseStreamError?
}

final class ResponseStreamLengthTests: XCTestCase {
    func testFactoryDeclaredLengthKeepsTrustedMetadata() {
        var response = Response.stream(
            contentType: "text/plain",
            contentLength: 5
        ) { writer in
            writer.writeString("hello")
        }

        guard case .stream(let stream) = response.body else {
            return XCTFail("Expected stream body")
        }

        XCTAssertTrue(
            response.contentLengthIsNormalized
        )
        XCTAssertEqual(
            stream.expectedContentLength,
            5
        )

        response.setHeader(
            "x-test",
            "1"
        )

        XCTAssertTrue(
            response.contentLengthIsNormalized
        )

        response.setHeader(
            "content-length",
            "4"
        )

        XCTAssertFalse(
            response.contentLengthIsNormalized
        )
    }

    func testFactoryDeclaredLengthMutationUsesUpdatedHeaderValidation() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let errors = StreamLengthErrorBox()

        app.get("/stream") { _ in
            Response
                .stream(
                    contentLength: 5,
                    onError: { error in
                        errors.error =
                            error as? ResponseStreamError
                    }
                ) { writer in
                    writer.writeString("hello")
                }
                .header(
                    "content-length",
                    "4"
                )
        }

        let channel = EmbeddedChannel(loop: loop)
        try addHandler(
            app,
            to: channel
        )

        try sendRequest(channel)
        loop.run()

        XCTAssertEqual(
            errors.error,
            .contentLengthExceeded(
                expected: 4,
                attempted: 5
            )
        )
        XCTAssertFalse(channel.isActive)
    }

    func testExactDeclaredLengthCompletesNormally() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response
                .stream { writer in
                    writer.writeString("hello")
                }
                .header(
                    "content-length",
                    "5"
                )
        }

        let channel = try makeChannel(app)

        try sendRequest(channel)

        XCTAssertEqual(
            try readParts(channel),
            [.head, .body("hello"), .end]
        )
        XCTAssertTrue(channel.isActive)
    }

    func testDeclaredLengthOverflowDoesNotWriteOverflowChunk() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let errors = StreamLengthErrorBox()

        app.get("/stream") { _ in
            Response
                .stream(
                    onError: { error in
                        errors.error =
                            error as? ResponseStreamError
                    }
                ) { writer in
                    writer.writeString("hello").flatMap {
                        writer.writeString("!")
                    }
                }
                .header(
                    "content-length",
                    "5"
                )
        }

        let channel = EmbeddedChannel(loop: loop)
        try addHandler(
            app,
            to: channel
        )

        try sendRequest(channel)
        loop.run()

        let parts = try readParts(channel)

        XCTAssertEqual(
            parts,
            [.head, .body("hello")]
        )
        XCTAssertEqual(
            errors.error,
            .contentLengthExceeded(
                expected: 5,
                attempted: 6
            )
        )
        XCTAssertFalse(channel.isActive)
    }

    func testDeclaredLengthUnderflowClosesWithoutEnd() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let errors = StreamLengthErrorBox()

        app.get("/stream") { _ in
            Response
                .stream(
                    onError: { error in
                        errors.error =
                            error as? ResponseStreamError
                    }
                ) { writer in
                    writer.writeString("hey")
                }
                .header(
                    "content-length",
                    "5"
                )
        }

        let channel = EmbeddedChannel(loop: loop)
        try addHandler(
            app,
            to: channel
        )

        try sendRequest(channel)
        loop.run()

        XCTAssertEqual(
            try readParts(channel),
            [.head, .body("hey")]
        )
        XCTAssertEqual(
            errors.error,
            .contentLengthMismatch(
                expected: 5,
                actual: 3
            )
        )
        XCTAssertFalse(channel.isActive)
    }

    func testDuplicateDeclaredLengthFailsBeforeStreamHead() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let errors = StreamLengthErrorBox()

        app.get("/stream") { _ in
            var response = Response.stream(
                onError: { error in
                    errors.error =
                        error as? ResponseStreamError
                }
            ) { writer in
                writer.writeString("body")
            }

            response.appendHeader(
                "content-length",
                "4"
            )
            response.appendHeader(
                "content-length",
                "4"
            )

            return response
        }

        let channel = EmbeddedChannel(loop: loop)
        try addHandler(
            app,
            to: channel
        )

        try sendRequest(channel)
        loop.run()

        let parts = try readParts(channel)

        guard
            case .some(
                .headStatus(
                    HTTPResponseStatus
                        .internalServerError
                        .code
                )
            ) = parts.first
        else {
            return XCTFail(
                "Expected 500 before stream output"
            )
        }

        XCTAssertEqual(
            errors.error,
            .ambiguousContentLength([
                "4",
                "4"
            ])
        )
    }

    func testCommaCombinedDeclaredLengthIsRejected() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let errors = StreamLengthErrorBox()

        app.get("/stream") { _ in
            Response
                .stream(
                    onError: { error in
                        errors.error =
                            error as? ResponseStreamError
                    }
                ) { writer in
                    writer.writeString("body")
                }
                .header(
                    "content-length",
                    "4, 4"
                )
        }

        let channel = EmbeddedChannel(loop: loop)
        try addHandler(
            app,
            to: channel
        )

        try sendRequest(channel)
        loop.run()

        let parts = try readParts(channel)

        guard
            case .some(
                .headStatus(
                    HTTPResponseStatus
                        .internalServerError
                        .code
                )
            ) = parts.first
        else {
            return XCTFail(
                "Expected 500 before stream output"
            )
        }

        XCTAssertEqual(
            errors.error,
            .ambiguousContentLength([
                "4, 4"
            ])
        )
    }

    func testDeclaredLengthIntegerOverflowIsRejected() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let errors = StreamLengthErrorBox()
        let value = String(Int.max) + "0"

        app.get("/stream") { _ in
            Response
                .stream(
                    onError: { error in
                        errors.error =
                            error as? ResponseStreamError
                    }
                ) { writer in
                    writer.writeString("body")
                }
                .header(
                    "content-length",
                    value
                )
        }

        let channel = EmbeddedChannel(loop: loop)
        try addHandler(
            app,
            to: channel
        )

        try sendRequest(channel)
        loop.run()

        let parts = try readParts(channel)

        guard
            case .some(
                .headStatus(
                    HTTPResponseStatus
                        .internalServerError
                        .code
                )
            ) = parts.first
        else {
            return XCTFail(
                "Expected 500 before stream output"
            )
        }

        XCTAssertEqual(
            errors.error,
            .invalidContentLength(value)
        )
    }

    func testInvalidDeclaredLengthFailsBeforeStreamHead() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let errors = StreamLengthErrorBox()

        app.get("/stream") { _ in
            Response
                .stream(
                    onError: { error in
                        errors.error =
                            error as? ResponseStreamError
                    }
                ) { writer in
                    writer.writeString("body")
                }
                .header(
                    "content-length",
                    "invalid"
                )
        }

        let channel = EmbeddedChannel(loop: loop)
        try addHandler(
            app,
            to: channel
        )

        try sendRequest(channel)
        loop.run()

        let parts = try readParts(channel)

        guard
            case .some(
                .headStatus(
                    HTTPResponseStatus
                        .internalServerError
                        .code
                )
            ) = parts.first
        else {
            return XCTFail(
                "Expected 500 before stream output"
            )
        }

        XCTAssertEqual(
            errors.error,
            .invalidContentLength("invalid")
        )
    }

    func testUnknownLengthStreamKeepsZeroAccountingPath() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response.stream { writer in
                writer.writeString("abc")
            }
        }

        let channel = try makeChannel(app)

        try sendRequest(channel)

        XCTAssertEqual(
            try readParts(channel),
            [.head, .body("abc"), .end]
        )
    }

    func testUserTransferEncodingIsStrippedOnFactoryDeclaredStreams() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response
                .stream(
                    contentType: "text/plain",
                    contentLength: 5
                ) { writer in
                    writer.writeString("hello")
                }
                .header(
                    "transfer-encoding",
                    "chunked"
                )
        }

        let channel = try makeChannel(app)
        try sendRequest(channel)

        let (head, body, sawEnd) = try readHeadAndBody(
            channel
        )

        XCTAssertEqual(
            head?.status,
            .ok
        )
        XCTAssertNil(
            head?.headers.first(
                name: "transfer-encoding"
            )
        )
        XCTAssertNotNil(
            head?.headers.first(
                name: "content-length"
            )
        )
        XCTAssertEqual(body, "hello")
        XCTAssertTrue(sawEnd)
        XCTAssertTrue(channel.isActive)
    }

    func testUserTransferEncodingIsStrippedOnUserDeclaredStreams() throws {
        let app = Application()

        app.get("/stream") { _ in
            Response
                .stream { writer in
                    writer.writeString("hello")
                }
                .header(
                    "content-length",
                    "5"
                )
                .header(
                    "transfer-encoding",
                    "chunked"
                )
        }

        let channel = try makeChannel(app)
        try sendRequest(channel)

        let (head, body, sawEnd) = try readHeadAndBody(
            channel
        )

        XCTAssertEqual(head?.status, .ok)
        XCTAssertNil(
            head?.headers.first(
                name: "transfer-encoding"
            )
        )
        XCTAssertEqual(body, "hello")
        XCTAssertTrue(sawEnd)
        XCTAssertTrue(channel.isActive)
    }

    private func readHeadAndBody(
        _ channel: EmbeddedChannel
    ) throws -> (
        HTTPResponseHead?,
        String?,
        sawEnd: Bool
    ) {
        var observedHead: HTTPResponseHead?
        var observedBody: String?
        var sawEnd = false

        while
            let part = try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        {
            switch part {
            case .head(let head):
                observedHead = head

            case .body(let data):
                guard
                    case .byteBuffer(let buffer) = data
                else {
                    continue
                }

                observedBody = buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                )

            case .end:
                sawEnd = true
            }
        }

        return (observedHead, observedBody, sawEnd)
    }

    private func makeChannel(
        _ app: Application
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try addHandler(
            app,
            to: channel
        )
        return channel
    }

    private func addHandler(
        _ app: Application,
        to channel: EmbeddedChannel
    ) throws {
        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try activateHTTPTestChannel(channel)
    }

    private func sendRequest(
        _ channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/stream"
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        channel.embeddedEventLoop.run()
    }

    private func readParts(
        _ channel: EmbeddedChannel
    ) throws -> [ObservedPart] {
        var result: [ObservedPart] = []

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head(let head):
                if head.status == .ok {
                    result.append(.head)
                } else {
                    result.append(
                        .headStatus(
                            head.status.code
                        )
                    )
                }

            case .body(let data):
                guard case .byteBuffer(let buffer) = data else {
                    return result
                }

                result.append(
                    .body(
                        buffer.getString(
                            at: buffer.readerIndex,
                            length: buffer.readableBytes
                        ) ?? ""
                    )
                )

            case .end:
                result.append(.end)
            }
        }

        return result
    }
}

private enum ObservedPart: Equatable {
    case head
    case headStatus(UInt)
    case body(String)
    case end
}
