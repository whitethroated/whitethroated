import XCTest
@testable import WhiteThroatedRuntime
import NIOCore
import NIOEmbedded
import NIOHTTP1

/// Independent runtime tests. They drive `RuntimeConnectionHandler`
/// directly through a test-constructed dispatcher, bypassing the
/// framework entirely.
final class RuntimeConnectionTests: XCTestCase {
    func testSyncGetLifecycle() throws {
        let fixture = Fixture(
            routes: [
                "GET /": .sync(
                    RuntimeSyncAction { _ in
                        .text("hello")
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.head.status, .ok)
        XCTAssertEqual(response.body, "hello")
        XCTAssertEqual(
            response.head.headers
                .first(name: "content-length"),
            "5"
        )
    }

    func testSyncExecutesSynchronouslyOnHead() throws {
        let executed = Counter()
        let fixture = Fixture(
            routes: [
                "GET /": .sync(
                    RuntimeSyncAction { _ in
                        executed.value += 1
                        return .text("hello")
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )

        XCTAssertEqual(executed.value, 1)
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.body, "hello")
    }

    func testKeepAliveServesSecondRequest() throws {
        let fixture = Fixture(
            routes: [
                "GET /": .sync(
                    RuntimeSyncAction { _ in
                        .text("one")
                    }
                ),
                "GET /two": .sync(
                    RuntimeSyncAction { _ in
                        .text("two")
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()
        XCTAssertEqual(
            try fixture.readResponse().body,
            "one"
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/two"
        )
        try fixture.writeEnd()
        XCTAssertEqual(
            try fixture.readResponse().body,
            "two"
        )
        XCTAssertTrue(fixture.channel.isActive)
    }

    func testConnectionCloseClosesChannel() throws {
        let fixture = Fixture(
            routes: [
                "GET /": .sync(
                    RuntimeSyncAction { _ in
                        .text("bye")
                    }
                )
            ]
        )

        var head = fixture.makeHead(
            method: .GET,
            uri: "/"
        )
        head.headers.replaceOrAdd(
            name: "connection",
            value: "close"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.headers
                .first(name: "connection"),
            "close"
        )
        fixture.loop.run()
        XCTAssertFalse(fixture.channel.isActive)
    }

    func testHeadSuppressesBody() throws {
        let fixture = Fixture(
            routes: [
                "HEAD /resource": .sync(
                    RuntimeSyncAction { _ in
                        .text("payload")
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .HEAD,
            uri: "/resource"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.headers
                .first(name: "content-length"),
            "7"
        )
        XCTAssertEqual(response.body, "")
        XCTAssertFalse(response.sawBodyPart)
    }

    func testUnknownRouteServesNotFound() throws {
        let fixture = Fixture(routes: [:])

        try fixture.writeHead(
            method: .GET,
            uri: "/missing"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.status,
            .notFound
        )
        XCTAssertEqual(response.body, "Not Found")
    }

    func testPreparedRoute() throws {
        var buffer =
            ByteBufferAllocator().buffer(capacity: 13)
        buffer.writeString("Hello, World!")
        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: "13"
        )
        let storage = RuntimePreparedResponse(
            status: .ok,
            headers: headers,
            bodyBuffer: buffer
        )
        let fixture = Fixture(
            routes: ["GET /": .prepared(storage)]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.head.status, .ok)
        XCTAssertEqual(
            response.body,
            "Hello, World!"
        )
    }

    func testBodylessStatusOmitsBody() throws {
        let fixture = Fixture(
            routes: [
                "GET /": .sync(
                    RuntimeSyncAction { _ in
                        RuntimeResponse(
                            status: .noContent,
                            headers: HTTPHeaders(),
                            body: .text(
                                "must-not-appear"
                            )
                        )
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.status,
            .noContent
        )
        XCTAssertFalse(response.sawBodyPart)
    }

    func testPostAggregationEchoesBody() throws {
        let fixture = Fixture(
            routes: [
                "POST /echo": .sync(
                    RuntimeSyncAction { request in
                        var body = request.body
                        let text = body
                            .readString(
                                length: body
                                    .readableBytes
                            ) ?? ""
                        return .text(text)
                    }
                )
            ]
        )

        var head = fixture.makeHead(
            method: .POST,
            uri: "/echo"
        )
        head.headers.replaceOrAdd(
            name: "content-length",
            value: "10"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        try fixture.writeBody("hello")
        try fixture.writeBody("world")
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.body,
            "helloworld"
        )
    }

    func testDeclaredBodyOverLimitReturns413() throws {
        let fixture = Fixture(
            routes: [
                "POST /": .sync(
                    RuntimeSyncAction { _ in
                        .text("unreachable")
                    }
                )
            ],
            maxBodyBytes: 8
        )

        var head = fixture.makeHead(
            method: .POST,
            uri: "/"
        )
        head.headers.replaceOrAdd(
            name: "content-length",
            value: "1024"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
    }

    func testActualBodyOverLimitReturns413() throws {
        let fixture = Fixture(
            routes: [
                "POST /": .sync(
                    RuntimeSyncAction { _ in
                        .text("unreachable")
                    }
                )
            ],
            maxBodyBytes: 8
        )

        var head = fixture.makeHead(
            method: .POST,
            uri: "/"
        )
        head.headers.replaceOrAdd(
            name: "content-length",
            value: "10"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        try fixture.writeBody("0123456789")
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.status,
            .payloadTooLarge
        )
    }

    func testAsyncRoute() throws {
        let fixture = Fixture(
            routes: [
                "GET /": .async(
                    RuntimeAsyncAction {
                        _, eventLoop in
                        eventLoop.makeSucceededFuture(
                            .text("async-hello")
                        )
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.body,
            "async-hello"
        )
    }

    func testAsyncFailureMapsError() throws {
        struct Boom: Error {}

        let fixture = Fixture(
            routes: [
                "GET /": .async(
                    RuntimeAsyncAction {
                        _, eventLoop in
                        eventLoop.makeFailedFuture(
                            Boom()
                        )
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.status,
            .internalServerError
        )
    }

    func testStreamingRequestSumsChunks() throws {
        let total = Counter()
        let fixture = Fixture(
            routes: [
                "POST /upload": .streaming(
                    RuntimeStreamingAction(
                        begin: {
                            _, eventLoop in
                            let registration =
                                RuntimeStreamRegistration(
                                    eventLoop:
                                        eventLoop
                                )
                            let consumer =
                                RuntimeStreamConsumer(
                                    onChunk: {
                                        buffer in
                                        total.value +=
                                            buffer
                                            .readableBytes
                                        return nil
                                    },
                                    onFinish: {
                                        eventLoop
                                            .makeSucceededFuture(
                                                .text(
                                                    "total=\(total.value)"
                                                )
                                            )
                                    }
                                )
                            let session =
                                RuntimeStreamSession(
                                    consumer:
                                        consumer,
                                    eventLoop:
                                        eventLoop
                                )
                            registration.register(
                                session
                            )

                            return RuntimeStreamingStart(
                                result: .future(
                                    session
                                        .responseFuture
                                ),
                                registration:
                                    registration,
                                maxBodyBytes: 1024,
                                declaredBodyTooLarge:
                                    false
                            )
                        },
                        runAggregated: {
                            _, eventLoop in
                            .response(
                                .text("aggregated")
                            )
                        }
                    )
                )
            ],
            hasStreamingRoutes: true
        )

        var head = fixture.makeHead(
            method: .POST,
            uri: "/upload"
        )
        head.headers.replaceOrAdd(
            name: "content-length",
            value: "6"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        try fixture.writeBody("ab")
        try fixture.writeBody("cdef")
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.body, "total=6")
    }

    func testStreamingBackpressureDeliversInOrder() throws {
        let gate = ChunkGate()
        let fixture = Fixture(
            routes: [
                "POST /upload": .streaming(
                    RuntimeStreamingAction(
                        begin: {
                            _, eventLoop in
                            gate.eventLoop =
                                eventLoop
                            let registration =
                                RuntimeStreamRegistration(
                                    eventLoop:
                                        eventLoop
                                )
                            let consumer =
                                RuntimeStreamConsumer(
                                    onChunk: {
                                        buffer in
                                        gate.received
                                            .append(
                                                buffer
                                            )
                                        let promise =
                                            eventLoop
                                            .makePromise(
                                                of: Void
                                                    .self
                                            )
                                        gate.pending
                                            .append(
                                                promise
                                            )
                                        return promise
                                            .futureResult
                                    },
                                    onFinish: {
                                        eventLoop
                                            .makeSucceededFuture(
                                                .text(
                                                    "chunks=\(gate.received.count)"
                                                )
                                            )
                                    }
                                )
                            let session =
                                RuntimeStreamSession(
                                    consumer:
                                        consumer,
                                    eventLoop:
                                        eventLoop
                                )
                            registration.register(
                                session
                            )

                            return RuntimeStreamingStart(
                                result: .future(
                                    session
                                        .responseFuture
                                ),
                                registration:
                                    registration,
                                maxBodyBytes: 1024,
                                declaredBodyTooLarge:
                                    false
                            )
                        },
                        runAggregated: {
                            _, _ in
                            .response(
                                .text("aggregated")
                            )
                        }
                    )
                )
            ],
            hasStreamingRoutes: true
        )

        var head = fixture.makeHead(
            method: .POST,
            uri: "/upload"
        )
        head.headers.replaceOrAdd(
            name: "content-length",
            value: "3"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        fixture.loop.run()

        try fixture.writeBody("a")
        fixture.loop.run()
        XCTAssertEqual(gate.received.count, 1)
        XCTAssertEqual(gate.pending.count, 1)

        // Chunk "b" must wait behind the outstanding future.
        try fixture.writeBody("b")
        fixture.loop.run()
        XCTAssertEqual(gate.received.count, 1)

        gate.pending.removeFirst().succeed(())
        fixture.loop.run()
        XCTAssertEqual(gate.received.count, 2)
        XCTAssertEqual(gate.pending.count, 1)

        try fixture.writeBody("c")
        fixture.loop.run()
        XCTAssertEqual(gate.received.count, 2)

        while !gate.pending.isEmpty {
            gate.pending.removeFirst().succeed(())
            fixture.loop.run()
        }

        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.body, "chunks=3")

        var ordered = ""
        for var chunk in gate.received {
            ordered +=
                chunk.readString(
                    length: chunk.readableBytes
                ) ?? ""
        }
        XCTAssertEqual(ordered, "abc")
    }

    func testStreamingResponseEmitsChunks() throws {
        let fixture = Fixture(
            routes: [
                "GET /": .sync(
                    RuntimeSyncAction { _ in
                        RuntimeResponse(
                            status: .ok,
                            headers: HTTPHeaders(),
                            body: .stream(
                                RuntimeResponseStream(
                                    produce: {
                                        writer in
                                        writer.writeString(
                                            "ab"
                                        )
                                        writer.writeStringAndFlush(
                                            "cd"
                                        )
                                        return writer
                                            .eventLoop
                                            .makeSucceededVoidFuture(
                                            )
                                    }
                                )
                            )
                        )
                    }
                )
            ]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.body, "abcd")
    }

    func testStreamLengthMismatchReportsError() throws {
        let seen = Counter()
        let responseAction = RuntimeSyncAction { _ in
            var headers = HTTPHeaders()
            headers.replaceOrAdd(
                name: "content-length",
                value: "10"
            )
            return RuntimeResponse(
                status: .ok,
                headers: headers,
                body: .stream(
                    RuntimeResponseStream(
                        produce: { writer in
                            writer.writeString(
                                "short"
                            )
                            return writer.eventLoop
                                .makeSucceededVoidFuture()
                        },
                        onError: { _ in
                            seen.value += 1
                        }
                    )
                )
            )
        }
        let fixture = Fixture(
            routes: ["GET /": .sync(responseAction)]
        )

        try fixture.writeHead(
            method: .GET,
            uri: "/"
        )
        try fixture.writeEnd()
        fixture.loop.run()

        XCTAssertEqual(seen.value, 1)
        XCTAssertFalse(fixture.channel.isActive)
    }

    func testExpectContinueRoundTrip() throws {
        let fixture = Fixture(
            routes: [
                "POST /": .sync(
                    RuntimeSyncAction { _ in
                        .text("done")
                    }
                )
            ]
        )

        var head = fixture.makeHead(
            method: .POST,
            uri: "/"
        )
        head.headers.replaceOrAdd(
            name: "expect",
            value: "100-continue"
        )
        head.headers.replaceOrAdd(
            name: "content-length",
            value: "0"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        fixture.loop.run()

        guard case .head(let interim)? =
            try fixture.channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected 100-continue interim head"
            )
        }
        XCTAssertEqual(interim.status, .continue)

        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.body, "done")
    }

    func testExpectationFailedRejectsEarly() throws {
        let fixture = Fixture(routes: [:])

        var head = fixture.makeHead(
            method: .POST,
            uri: "/"
        )
        head.headers.replaceOrAdd(
            name: "expect",
            value: "something-else"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(
            response.head.status,
            .expectationFailed
        )
        fixture.loop.run()
        XCTAssertFalse(fixture.channel.isActive)
    }

    func testMiddlewarePipelineDispatch() throws {
        let fixture = Fixture(
            routes: [:],
            hasMiddleware: true,
            pipeline: { request, eventLoop in
                var body = request.body
                let text = body.readString(
                    length: body.readableBytes
                ) ?? ""
                return .response(
                    .text("mw:\(text)")
                )
            }
        )

        var head = fixture.makeHead(
            method: .POST,
            uri: "/anything"
        )
        head.headers.replaceOrAdd(
            name: "content-length",
            value: "3"
        )
        try fixture.channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        try fixture.writeBody("abc")
        try fixture.writeEnd()

        let response = try fixture.readResponse()
        XCTAssertEqual(response.body, "mw:abc")
    }

    func testChannelErrorClosesConnection() throws {
        struct Boom: Error {}

        let fixture = Fixture(
            routes: [
                "GET /": .sync(
                    RuntimeSyncAction { _ in
                        .text("hello")
                    }
                )
            ]
        )

        fixture.channel.pipeline.fireErrorCaught(
            Boom()
        )
        fixture.loop.run()
        XCTAssertFalse(fixture.channel.isActive)
    }
}

private final class Counter: @unchecked Sendable {
    var value = 0
}

private final class ChunkGate: @unchecked Sendable {
    var eventLoop: EventLoop?
    var received: [ByteBuffer] = []
    var pending: [EventLoopPromise<Void>] = []
}

extension RuntimeResponse {
    fileprivate static func text(
        _ value: String
    ) -> RuntimeResponse {
        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: String(value.utf8.count)
        )
        return RuntimeResponse(
            status: .ok,
            headers: headers,
            body: .text(value),
            contentLengthIsNormalized: true
        )
    }
}

private struct ReadResponse {
    let head: HTTPResponseHead
    let body: String
    let sawBodyPart: Bool
}

private final class Fixture {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let routes: [String: RuntimeRouteAction]

    init(
        routes: [String: RuntimeRouteAction],
        maxBodyBytes: Int = 1_048_576,
        hasMiddleware: Bool = false,
        hasStreamingRoutes: Bool = false,
        pipeline: (
            @Sendable (
                RuntimeRequest,
                EventLoop
            ) -> RuntimeDispatchResult
        )? = nil
    ) {
        self.routes = routes
        self.channel = EmbeddedChannel(loop: loop)

        let dispatcher = RuntimeDispatcher(
            hasMiddleware: hasMiddleware,
            hasStreamingRoutes: hasStreamingRoutes,
            hasStreamingRoute: { method in
                hasStreamingRoutes
                    && method == .POST
            },
            lookup: { [routes] head in
                routes[
                    "\(head.method) \(head.uri)"
                ] ?? .prepared(
                    Fixture.fixed(
                        status: .notFound,
                        body: "Not Found"
                    )
                )
            },
            dispatchPipeline: { request, eventLoop in
                pipeline?(
                    request,
                    eventLoop
                ) ?? .prepared(
                    Fixture.fixed(
                        status: .notFound,
                        body: "Not Found"
                    )
                )
            },
            mapError: { _, eventLoop, _ in
                .response(
                    RuntimeResponse(
                        status:
                            .internalServerError,
                        headers:
                            HTTPHeaders(),
                        body: .text(
                            "Internal Server Error"
                        )
                    )
                )
            },
            notFound: Fixture.fixed(
                status: .notFound,
                body: "Not Found"
            ),
            payloadTooLarge: Fixture.fixed(
                status: .payloadTooLarge,
                body: "Payload Too Large"
            ),
            expectationFailed: Fixture.fixed(
                status: .expectationFailed,
                body: "Expectation Failed"
            ),
            internalServerError: Fixture.fixed(
                status: .internalServerError,
                body: "Internal Server Error"
            )
        )

        try! channel.pipeline.syncOperations
            .addHandler(
                RuntimeConnectionHandler(
                    dispatcher: dispatcher,
                    configuration:
                        RuntimeServerConfiguration(
                            maxRequestBodyBytes:
                                maxBodyBytes
                        )
                )
            )
        try! channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()
    }

    static func fixed(
        status: HTTPResponseStatus,
        body: String
    ) -> RuntimePreparedResponse {
        var buffer = ByteBufferAllocator().buffer(
            capacity: body.utf8.count
        )
        buffer.writeString(body)
        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: String(buffer.readableBytes)
        )

        return RuntimePreparedResponse(
            status: status,
            headers: headers,
            bodyBuffer: buffer
        )
    }

    func makeHead(
        method: HTTPMethod,
        uri: String
    ) -> HTTPRequestHead {
        HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: uri
        )
    }

    func writeHead(
        method: HTTPMethod,
        uri: String
    ) throws {
        try channel.writeInbound(
            HTTPServerRequestPart.head(
                makeHead(
                    method: method,
                    uri: uri
                )
            )
        )
        loop.run()
    }

    func writeBody(
        _ text: String
    ) throws {
        var buffer =
            ByteBufferAllocator().buffer(
                capacity: text.utf8.count
            )
        buffer.writeString(text)
        try channel.writeInbound(
            HTTPServerRequestPart.body(buffer)
        )
        loop.run()
    }

    func writeEnd() throws {
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        loop.run()
        loop.run()
    }

    func readResponse() throws -> ReadResponse {
        loop.run()

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            throw FixtureError.missingHead
        }

        var body = ""
        var sawBodyPart = false

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .body(.byteBuffer(var buffer)):
                sawBodyPart = true
                body +=
                    buffer.readString(
                        length: buffer
                            .readableBytes
                    ) ?? ""

            case .body(.fileRegion):
                sawBodyPart = true

            case .end:
                return ReadResponse(
                    head: head,
                    body: body,
                    sawBodyPart: sawBodyPart
                )

            default:
                break
            }
        }

        throw FixtureError.missingEnd
    }
}

private enum FixtureError: Error {
    case missingHead
    case missingEnd
}
