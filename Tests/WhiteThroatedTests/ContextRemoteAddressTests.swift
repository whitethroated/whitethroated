import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ContextRemoteAddressTests: XCTestCase {
    func testFutureHandlerReceivesChannelRemoteAddress() throws {
        let app = Application()
        let remote = try makeRemoteAddress()

        app.get("/peer") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text(
                    context.remoteAddress?.description
                        ?? "nil"
                )
            )
        }

        let channel = try makeChannel(
            app,
            remoteAddress: remote
        )

        try sendRequest(
            method: .GET,
            uri: "/peer",
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            remote.description
        )
    }

    func testStreamingHandlerReceivesChannelRemoteAddress() throws {
        let app = Application()
        let remote = try makeRemoteAddress()

        app.postStream("/stream") {
            _, context in

            let peer =
                context.remoteAddress?.description
                ?? "nil"

            return BodyStreamConsumer(
                onChunk: { _ in },
                onEnd: {
                    .text(peer)
                }
            )
        }

        let channel = try makeChannel(
            app,
            remoteAddress: remote
        )

        try sendRequest(
            method: .POST,
            uri: "/stream",
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            remote.description
        )
    }

    func testErrorHandlerReceivesChannelRemoteAddress() throws {
        enum TestError: Error {
            case failed
        }

        let app = Application()
        let remote = try makeRemoteAddress()

        app.onError { _, context in
            .text(
                context.remoteAddress?.description
                    ?? "nil",
                status: .badRequest
            )
        }

        app.get("/fail") { _, context in
            context.eventLoop.makeFailedFuture(
                TestError.failed
            )
        }

        let channel = try makeChannel(
            app,
            remoteAddress: remote
        )

        try sendRequest(
            method: .GET,
            uri: "/fail",
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.status,
            .badRequest
        )
        XCTAssertEqual(
            response.body,
            remote.description
        )
    }

    func testContextDefaultsToNoRemoteAddressOutsideTransport() {
        let context = Context(
            eventLoop: EmbeddedEventLoop()
        )

        XCTAssertNil(context.remoteAddress)
    }

    private func makeRemoteAddress() throws
        -> SocketAddress
    {
        try SocketAddress(
            ipAddress: "203.0.113.10",
            port: 4242
        )
    }

    private func makeChannel(
        _ app: Application,
        remoteAddress: SocketAddress
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try channel.connect(
            to: remoteAddress
        ).wait()

        return channel
    }

    private func sendRequest(
        method: NIOHTTP1.HTTPMethod,
        uri: String,
        to channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: method,
                    uri: uri
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }

    private func readResponse(
        from channel: EmbeddedChannel
    ) throws -> (
        status: HTTPResponseStatus,
        body: String
    ) {
        guard
            case .head(let head)? =
                try channel.readOutbound(
                    as:
                        HTTPServerResponsePart.self
                )
        else {
            throw TestFailure.missingHead
        }

        var body = ""

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                throw TestFailure.unexpectedHead

            case .body(let data):
                guard
                    case .byteBuffer(let buffer) =
                        data
                else {
                    throw TestFailure.unexpectedBody
                }

                body += buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ) ?? ""

            case .end:
                return (
                    head.status,
                    body
                )
            }
        }

        throw TestFailure.missingEnd
    }
}

private enum TestFailure: Error {
    case missingHead
    case missingEnd
    case unexpectedHead
    case unexpectedBody
}
