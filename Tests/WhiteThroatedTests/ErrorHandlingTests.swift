import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix

private enum TestApplicationError: Error {
    case failed
    case errorHandlerFailed
}

final class ErrorHandlingTests: XCTestCase {
    func testSyncErrorHandlerHandlesFailedFutureRoute() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let errorHandler: SyncErrorHandler = {
            _, _ in

            .text(
                "handled",
                status: .badRequest
            )
        }

        app.onError(errorHandler)

        app.get("/failed") { _, context in
            context.eventLoop.makeFailedFuture(
                TestApplicationError.failed
            )
        }

        let channel = try makeChannel(
            app,
            loop: loop
        )

        try writeRequest(
            "/failed",
            to: channel
        )
        loop.run()

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .badRequest
        )
        XCTAssertEqual(
            response.body,
            "handled"
        )
    }

    func testFutureErrorHandlerReturnsFutureResponse() throws {
        let app = Application()
        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: 1
        )

        defer {
            try? group.syncShutdownGracefully()
        }

        let eventLoop = group.next()

        let errorHandler: ErrorHandler = {
            _, context in

            context.eventLoop.makeSucceededFuture(
                .text(
                    "future-error",
                    status: .serviceUnavailable
                )
            )
        }

        app.onError(errorHandler)

        let result = app.respondError(
            TestApplicationError.failed,
            on: eventLoop
        )

        guard case .future(let future) = result else {
            return XCTFail(
                "Expected future error handler response"
            )
        }

        let response = try future.wait()

        XCTAssertEqual(
            response.status,
            .serviceUnavailable
        )

        guard case .text(let body) = response.body else {
            return XCTFail(
                "Expected text response"
            )
        }

        XCTAssertEqual(
            body,
            "future-error"
        )
    }

    func testAsyncErrorHandlerBridgesThroughFuture() throws {
        let app = Application()
        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: 1
        )

        defer {
            try? group.syncShutdownGracefully()
        }

        let eventLoop = group.next()

        let errorHandler: AsyncErrorHandler = {
            _, _ async throws in

            .text(
                "async-error",
                status: .unprocessableEntity
            )
        }

        app.onError(errorHandler)

        let result = app.respondError(
            TestApplicationError.failed,
            on: eventLoop
        )

        guard case .future(let future) = result else {
            return XCTFail(
                "Expected async error handler future"
            )
        }

        let response = try future.wait()

        XCTAssertEqual(
            response.status,
            .unprocessableEntity
        )

        guard case .text(let body) = response.body else {
            return XCTFail(
                "Expected text response"
            )
        }

        XCTAssertEqual(
            body,
            "async-error"
        )
    }

    func testFailedErrorHandlerFallsBackToBuiltIn500() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let errorHandler: ErrorHandler = {
            _, context in

            context.eventLoop.makeFailedFuture(
                TestApplicationError.errorHandlerFailed
            )
        }

        app.onError(errorHandler)

        app.get("/failed") { _, context in
            context.eventLoop.makeFailedFuture(
                TestApplicationError.failed
            )
        }

        let channel = try makeChannel(
            app,
            loop: loop
        )

        try writeRequest(
            "/failed",
            to: channel
        )
        loop.run()

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .internalServerError
        )
        XCTAssertEqual(
            response.body,
            "Internal Server Error"
        )
    }

    func testStreamingChunkFailureUsesErrorHandler() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        let errorHandler: SyncErrorHandler = {
            _, _ in

            .text(
                "stream-error",
                status: .conflict
            )
        }

        app.onError(errorHandler)

        app.postStream("/upload") {
            _, context in

            BodyStreamConsumer(
                onChunk: { _ in
                    context.eventLoop
                        .makeFailedFuture(
                            TestApplicationError.failed
                        )
                },
                onEnd: {
                    context.eventLoop
                        .makeSucceededFuture(
                            .text("unexpected")
                        )
                }
            )
        }

        let channel = try makeChannel(
            app,
            loop: loop
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .POST,
                    uri: "/upload"
                )
            )
        )

        var body = channel.allocator.buffer(
            capacity: 3
        )
        body.writeString("abc")

        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(body)
        )
        loop.run()

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        loop.run()

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .conflict
        )
        XCTAssertEqual(
            response.body,
            "stream-error"
        )
    }

    func testDefaultErrorHandlerRemains500() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/failed") { _, context in
            context.eventLoop.makeFailedFuture(
                TestApplicationError.failed
            )
        }

        let channel = try makeChannel(
            app,
            loop: loop
        )

        try writeRequest(
            "/failed",
            to: channel
        )
        loop.run()

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .internalServerError
        )
    }

    private func makeChannel(
        _ app: Application,
        loop: EmbeddedEventLoop
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel(
            loop: loop
        )

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try activateHTTPTestChannel(channel)

        return channel
    }

    private func writeRequest(
        _ uri: String,
        to channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
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
        head: HTTPResponseHead,
        body: String
    ) {
        channel.embeddedEventLoop.run()
        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            throw ErrorHandlingTestError.missingHead
        }

        var body = ""

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                throw ErrorHandlingTestError.unexpectedHead

            case .body(let data):
                guard case .byteBuffer(let buffer) = data else {
                    throw ErrorHandlingTestError.unexpectedBody
                }

                body += buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ) ?? ""

            case .end:
                return (head, body)
            }
        }

        throw ErrorHandlingTestError.missingEnd
    }
}

private enum ErrorHandlingTestError: Error {
    case missingHead
    case missingEnd
    case unexpectedHead
    case unexpectedBody
}
