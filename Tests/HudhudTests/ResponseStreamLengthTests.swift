import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class StreamLengthErrorBox:
    @unchecked Sendable
{
    var error: ResponseStreamError?
}

final class ResponseStreamLengthTests: XCTestCase {
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
