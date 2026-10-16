import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class StreamCounter: @unchecked Sendable {
    var bytes = 0
    var errors = 0
    var sessions = 0
    var chunks: [String] = []
    var gate: EventLoopPromise<Void>?
}

final class BodyStreamingTests: XCTestCase {
    func testThrowingEndHandlerUsesApplicationErrorPipeline() throws {
        enum EndError: Error {
            case failed
        }

        let app = Application()
        let errors = StreamCounter()

        app.onError { error, _ in
            if error is EndError {
                return .text(
                    "end-failed",
                    status: .badRequest
                )
            }

            return .internalServerError()
        }

        app.postStream("/upload") { _, _ in
            BodyStreamConsumer(
                onChunkThrowing: { _ in },
                onEndThrowing: {
                    throw EndError.failed
                },
                onError: { error in
                    if error is EndError {
                        errors.errors += 1
                    }
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .badRequest
        )
        XCTAssertEqual(
            response.body,
            "end-failed"
        )
        XCTAssertEqual(
            errors.errors,
            1
        )
    }

    func testSyncChunkConsumerDoesNotRequireFuture() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream("/upload") { _, _ in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                },
                onEnd: {
                    .text(String(counter.bytes))
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        try writeBody(
            "def",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.body,
            "6"
        )
        XCTAssertEqual(
            counter.bytes,
            6
        )
    }

    func testThrowingSyncChunkConsumerSucceedsWithoutFuture() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream("/upload") { _, _ in
            BodyStreamConsumer(
                onChunkThrowing: { buffer in
                    counter.bytes += buffer.readableBytes
                },
                onEnd: {
                    .text(String(counter.bytes))
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.body,
            "3"
        )
    }

    func testThrowingSyncChunkConsumerFailureUsesErrorPath()
        throws
    {
        enum ConsumerError: Error {
            case failed
        }

        let app = Application()
        let counter = StreamCounter()

        app.postStream("/upload") { _, _ in
            BodyStreamConsumer(
                onChunkThrowing: { _ in
                    throw ConsumerError.failed
                },
                onEnd: {
                    counter.bytes = -1
                    return .text("unexpected")
                },
                onError: { error in
                    if error is ConsumerError {
                        counter.errors += 1
                    }
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .internalServerError
        )
        XCTAssertEqual(
            counter.errors,
            1
        )
        XCTAssertEqual(
            counter.bytes,
            0
        )
    }

    func testStreamingConsumerSupportsSynchronousEndResponse() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream("/upload") { _, _ in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    .text(
                        "bytes:\(counter.bytes)"
                    )
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            "bytes:3"
        )
    }

    func testStreamingRouteConsumesChunksWithoutAggregation() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream(
            "/upload/:id",
            maxBodyBytes: 64
        ) { request, context in
            XCTAssertEqual(
                request.parameter("id"),
                "42"
            )
            XCTAssertEqual(
                request.query("mode"),
                "stream"
            )

            return BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text(String(counter.bytes))
                    )
                }
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead(
            "/upload/42?mode=stream"
        )
        head.headers.add(
            name: "content-length",
            value: "6"
        )

        try write(
            .head(head),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        try writeBody(
            "def",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            "6"
        )
        XCTAssertEqual(
            counter.bytes,
            6
        )
    }

    func testFastMiddlewareCanShortCircuitStreamingRoute() throws {
        let app = Application()
        let counter = StreamCounter()

        app.useFast { request, _, next in
            guard request.header("authorization") == "ok" else {
                return .response(
                    .text(
                        "blocked",
                        status: .unauthorized
                    )
                )
            }

            return next(request)
        }

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("accepted")
                    )
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "discard-me",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .unauthorized
        )
        XCTAssertEqual(
            response.body,
            "blocked"
        )
        XCTAssertEqual(
            counter.bytes,
            0
        )
    }

    func testDeclaredOversizedStreamStillHonorsFastMiddleware() throws {
        let app = Application()
        let counter = StreamCounter()

        app.useFast { request, _, next in
            guard request.header("authorization") == "ok" else {
                return .response(
                    .text(
                        "blocked",
                        status: .unauthorized
                    )
                )
            }

            return next(request)
        }

        app.postStream(
            "/upload",
            maxBodyBytes: 4
        ) { _, context in
            counter.sessions += 1

            return BodyStreamConsumer(
                onChunk: { _ in nil },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("unexpected")
                    )
                }
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead("/upload")
        head.headers.add(
            name: "content-length",
            value: "8"
        )

        try write(
            .head(head),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .unauthorized
        )
        XCTAssertEqual(
            response.body,
            "blocked"
        )
        XCTAssertEqual(
            counter.sessions,
            0
        )
    }

    func testDeclaredOversizedStreamingBodyNeverCreatesConsumer() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream(
            "/upload",
            maxBodyBytes: 4
        ) { _, context in
            counter.sessions += 1

            return BodyStreamConsumer(
                onChunk: { _ in nil },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("unexpected")
                    )
                },
                onError: { _ in
                    counter.errors += 1
                }
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead("/upload")
        head.headers.add(
            name: "content-length",
            value: "8"
        )

        try write(
            .head(head),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
        XCTAssertEqual(
            counter.sessions,
            0
        )
        XCTAssertEqual(
            counter.errors,
            0
        )
    }

    func testStreamingRouteSpecificBodyLimitReturns413() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream(
            "/upload",
            maxBodyBytes: 4
        ) { _, context in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("unexpected")
                    )
                }
            )
        }

        let channel = try makeChannel(app)
        var head = makeHead("/upload")
        head.headers.add(
            name: "content-length",
            value: "8"
        )

        try write(
            .head(head),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
        XCTAssertEqual(
            counter.bytes,
            0
        )
    }

    func testChunkedStreamingLimitReturns413WhenCrossedMidBody() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream(
            "/upload",
            maxBodyBytes: 4
        ) { _, context in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("unexpected")
                    )
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "123",
            to: channel
        )
        try writeBody(
            "456",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
        XCTAssertEqual(
            counter.bytes,
            3
        )
    }

    func testStreamingErrorHookRunsOnChunkFailure() throws {
        enum ConsumerError: Error {
            case failed
        }

        let app = Application()
        let counter = StreamCounter()
        let loop = EmbeddedEventLoop()

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { _ in
                    context.eventLoop.makeFailedFuture(
                        ConsumerError.failed
                    )
                },
                onEnd: {
                    counter.bytes = -1

                    return context.eventLoop
                        .makeSucceededFuture(
                            .text("unexpected")
                        )
                },
                onError: { error in
                    if error is ConsumerError {
                        counter.errors += 1
                    }
                }
            )
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

        try activateHTTPTestChannel(channel)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        loop.run()

        try write(
            .end(nil),
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
            counter.errors,
            1
        )
        XCTAssertEqual(
            counter.bytes,
            0
        )
    }

    func testStreamingErrorHookRunsOnceWhenBodyLimitIsExceeded() throws {
        let app = Application()
        let counter = StreamCounter()

        app.postStream(
            "/upload",
            maxBodyBytes: 4
        ) { _, context in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("unexpected")
                    )
                },
                onError: { error in
                    if
                        let streamError =
                            error as? BodyStreamError,
                        case .payloadTooLarge = streamError
                    {
                        counter.errors += 1
                    }
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "123",
            to: channel
        )
        try writeBody(
            "456",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
        XCTAssertEqual(
            counter.bytes,
            3
        )
        XCTAssertEqual(
            counter.errors,
            1
        )
    }

    func testChunkConsumerFailureReturns500WithoutEndingConsumer() throws {
        enum ConsumerError: Error {
            case failed
        }

        let app = Application()
        let counter = StreamCounter()
        let loop = EmbeddedEventLoop()

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { _ in
                    context.eventLoop.makeFailedFuture(
                        ConsumerError.failed
                    )
                },
                onEnd: {
                    counter.bytes = -1

                    return context.eventLoop
                        .makeSucceededFuture(
                            .text("unexpected")
                        )
                }
            )
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

        try activateHTTPTestChannel(channel)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        loop.run()

        try write(
            .end(nil),
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
            counter.bytes,
            0
        )
    }

    func testAsyncChunkConsumerAppliesBackpressureAndPreservesOrder() throws {
        let app = Application()
        let counter = StreamCounter()
        let loop = EmbeddedEventLoop()

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { buffer in
                    let value = buffer.getString(
                        at: buffer.readerIndex,
                        length: buffer.readableBytes
                    ) ?? ""

                    counter.chunks.append(value)

                    if counter.gate == nil {
                        let promise =
                            context.eventLoop.makePromise(
                                of: Void.self
                            )
                        counter.gate = promise
                        return promise.futureResult
                    }

                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text(
                            counter.chunks.joined()
                        )
                    )
                }
            )
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

        try activateHTTPTestChannel(channel)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "a",
            to: channel
        )
        try writeBody(
            "b",
            to: channel
        )

        XCTAssertEqual(
            counter.chunks,
            ["a"]
        )

        counter.gate?.succeed(())
        loop.run()

        XCTAssertEqual(
            counter.chunks,
            ["a", "b"]
        )

        try write(
            .end(nil),
            to: channel
        )
        loop.run()

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.body,
            "ab"
        )
    }

    func testAsyncMiddlewareCanDelayStreamingRouteResolution() throws {
        let app = Application()
        let counter = StreamCounter()
        let loop = EmbeddedEventLoop()

        app.use { request, context, next in
            let promise = context.eventLoop.makePromise(
                of: Response.self
            )

            context.eventLoop.execute {
                next(request).cascade(
                    to: promise
                )
            }

            return promise.futureResult
        }

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text(String(counter.bytes))
                    )
                }
            )
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

        try activateHTTPTestChannel(channel)

        try write(
            .head(makeHead("/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )

        XCTAssertEqual(
            counter.bytes,
            0
        )

        loop.run()

        XCTAssertEqual(
            counter.bytes,
            3
        )

        try write(
            .end(nil),
            to: channel
        )
        loop.run()

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.body,
            "3"
        )
    }

    func testRouteGroupSupportsStreamingRoutes() throws {
        let app = Application()
        let counter = StreamCounter()
        let api = app.group("/api")

        api.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { buffer in
                    counter.bytes += buffer.readableBytes
                    return nil
                },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .text("ok")
                    )
                }
            )
        }

        let channel = try makeChannel(app)

        try write(
            .head(makeHead("/api/upload")),
            to: channel
        )
        try writeBody(
            "abc",
            to: channel
        )
        try write(
            .end(nil),
            to: channel
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.head.status,
            .ok
        )
        XCTAssertEqual(
            counter.bytes,
            3
        )
    }

    func testApplicationWithoutStreamingRoutesKeepsStreamingFlagDisabled() {
        let app = Application()

        app.get(
            "/health",
            response: .text("ok")
        )

        XCTAssertFalse(
            app.hasStreamingRoutes
        )

        app.postStream("/upload") { _, context in
            BodyStreamConsumer(
                onChunk: { _ in nil },
                onEnd: {
                    context.eventLoop.makeSucceededFuture(
                        .noContent()
                    )
                }
            )
        }

        XCTAssertTrue(
            app.hasStreamingRoutes
        )
        XCTAssertTrue(
            app.hasStreamingRoute(
                for: .POST
            )
        )
        XCTAssertFalse(
            app.hasStreamingRoute(
                for: .GET
            )
        )
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

        try activateHTTPTestChannel(channel)

        return channel
    }

    private func makeHead(
        _ uri: String
    ) -> HTTPRequestHead {
        HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: uri
        )
    }

    private func write(
        _ part: HTTPServerRequestPart,
        to channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(part)
    }

    private func writeBody(
        _ value: String,
        to channel: EmbeddedChannel
    ) throws {
        var buffer = channel.allocator.buffer(
            capacity: value.utf8.count
        )
        buffer.writeString(value)

        try write(
            .body(buffer),
            to: channel
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
            throw TestError.missingHead
        }

        var body = ""

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                throw TestError.unexpectedHead

            case .body(let data):
                guard case .byteBuffer(let buffer) = data else {
                    throw TestError.unexpectedBody
                }

                body += buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ) ?? ""

            case .end:
                return (head, body)
            }
        }

        throw TestError.missingEnd
    }
}

private enum TestError: Error {
    case missingHead
    case missingEnd
    case unexpectedHead
    case unexpectedBody
}
