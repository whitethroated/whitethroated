import XCTest

@testable import WhiteThroatedRuntime
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix

/// Byte-for-byte equivalence between the stock NIOHTTP1 pipeline and
/// the Tier 1 `WTHTTP1ConnectionHandler`.
///
/// Every case feeds identical raw bytes through both channels (stock:
/// decoder + pipelining + error handler + encoder + connection
/// handler; Tier 1: the single experimental handler) and requires
/// identical outbound bytes plus identical channel-active state.
/// Documented Tier 1 divergences (streaming routes, fileRegion/stream
/// bodies) are covered by direct Tier 1 tests instead.
final class WTHTTP1EquivalenceTests: XCTestCase {
    func testMinimalGetTwice() throws {
        try assertEquivalent(
            writes: [
                "GET / HTTP/1.1\r\n\r\n",
                "GET / HTTP/1.1\r\n\r\n",
            ]
        )
    }

    func testGetWithHostHeader() throws {
        try assertEquivalent(
            writes: [
                "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
            ]
        )
    }

    func testPreparedTwice() throws {
        try assertEquivalent(
            writes: [
                "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
                "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
            ]
        )
    }

    func testHeadPrepared() throws {
        try assertEquivalent(
            writes: [
                "HEAD /prep HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testHeadSync() throws {
        try assertEquivalent(
            writes: [
                "HEAD / HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testPostEchoSingleWrite() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
            ]
        )
    }

    func testPostEchoSplitWrites() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhe",
                "llo w",
                "orld",
            ]
        )
    }

    func testPostEchoEmptyBody() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"
            ]
        )
    }

    func testPostEchoChunked() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
            ]
        )
    }

    func testPostEchoChunkedSplit() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe",
                "llo\r\n0\r\nX-T",
                ": v\r\n\r\n",
            ]
        )
    }

    func testChunkedIdentityEncodingAccepted() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity, chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
            ]
        )
    }

    func testContinueFlow() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n",
                "hello",
            ]
        )
    }

    func testContinueChunkedFlow() throws {
        try assertEquivalent(
            writes: [
                "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n",
                "5\r\nhello\r\n0\r\n\r\n",
            ]
        )
    }

    func testExpectationFailed() throws {
        // No body is sent after the early 417, so stock's decoder
        // hits incomplete-EOF at close and the embedded channel
        // captures a post-close 400 that can never reach a real
        // socket (writes after close are dropped). Asserted
        // explicitly rather than hidden.
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: cheese\r\n\r\n"
        )
        try fixture.assertEqualAllowingStockPostClose400()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testEarlyRejectThenBodyDropped() throws {
        // The full request (head + body) in one write: both sides
        // answer 417, drop the straggler body, and close with no
        // post-close artifact on either side.
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: cheese\r\n\r\nhello"
        )
        try fixture.assertEqual()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testEarlyRejectThenBodySplitWrites() throws {
        // Split writes: the embedded channel closes synchronously
        // between the two inbound writes, so stock's decoder hits
        // incomplete-EOF at close and the artifact 400 is captured.
        // On a real socket that post-close write is dropped; the
        // wire truth (417 only) is proven by the single-write
        // variant above plus Tier 1's exact 417 bytes here.
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: cheese\r\n\r\n",
            runLoops: false
        )
        try fixture.writeBoth(
            "hello",
            runLoops: false
        )
        fixture.driveLoops()
        fixture.driveLoops()
        try fixture.assertEqualAllowingStockPostClose400()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testDeclaredTooLargeConsumesThen413() throws {
        let fixture = EquivalenceFixture(
            maxBodyBytes: 10
        )

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n"
        )
        try fixture.writeBoth(
            String(
                repeating: "a",
                count: 100
            )
        )
        try fixture.assertEqual()
        XCTAssertTrue(fixture.stockChannel.isActive)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testChunkedTooLarge413() throws {
        let fixture = EquivalenceFixture(
            maxBodyBytes: 10
        )

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n64\r\n"
        )
        try fixture.writeBoth(
            String(
                repeating: "b",
                count: 100
            ) + "\r\n0\r\n\r\n"
        )
        try fixture.assertEqual()
        XCTAssertTrue(fixture.stockChannel.isActive)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testContinueOverLimitEarly413() throws {
        // Same incomplete-EOF post-close 400 artifact as
        // testExpectationFailed; see that test for why it is
        // asserted explicitly.
        let fixture = EquivalenceFixture(
            maxBodyBytes: 10
        )

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nExpect: 100-continue\r\n\r\n"
        )
        try fixture.assertEqualAllowingStockPostClose400()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testConnectionClose() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        )
        try fixture.assertEqual()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testHTTP10DefaultsClose() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET / HTTP/1.0\r\n\r\n"
        )
        try fixture.assertEqual()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testHTTP10KeepAlive() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
        )
        try fixture.writeBoth(
            "GET /prep HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
        )
        try fixture.assertEqual()
        XCTAssertTrue(fixture.stockChannel.isActive)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testPipelinedGets() throws {
        try assertEquivalent(
            writes: [
                "GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /prep HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testPipelinedAsyncOrdering() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /async HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        fixture.succeedAsync(value: "late")
        try fixture.assertEqual()
        XCTAssertTrue(fixture.stockChannel.isActive)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testMalformedHeader400() throws {
        let fixture = EquivalenceFixture()

        var bad = Array(
            "GET / HTTP/1.1\r\nX-Bad: a".utf8
        )
        bad.append(0x01)
        bad += Array("b\r\n\r\n".utf8)
        try fixture.writeBoth(bytes: bad)
        try fixture.assertEqual()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testSmugglingAmbiguity400() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello"
        )
        try fixture.assertEqual()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testBadChunkFraming400() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\nZZZ\r\n"
        )
        try fixture.assertEqual()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
    }

    func testUnknownRoute404() throws {
        try assertEquivalent(
            writes: [
                "GET /missing HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testConnectStripsFraming() throws {
        try assertEquivalent(
            writes: [
                "CONNECT / HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testUpgradeRoutedNormally() throws {
        try assertEquivalent(
            writes: [
                "GET /ws HTTP/1.1\r\nHost: x\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"
            ]
        )
    }

    func testNotModifiedStripsLengthOnWire() throws {
        try assertEquivalent(
            writes: [
                "GET /notmodified HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testNoContentStripsLengthOnWire() throws {
        try assertEquivalent(
            writes: [
                "GET /nocontent HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testUnnormalizedRepairsLength() throws {
        try assertEquivalent(
            writes: [
                "GET /nocl HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testAsyncFailureMapsError() throws {
        try assertEquivalent(
            writes: [
                "GET /fail HTTP/1.1\r\nHost: x\r\n\r\n"
            ]
        )
    }

    func testMixedKeepAliveSequence() throws {
        try assertEquivalent(
            writes: [
                "GET / HTTP/1.1\r\n\r\n",
                "POST /echo HTTP/1.1\r\nContent-Length: 2\r\n\r\nhi",
                "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
                "GET /missing HTTP/1.1\r\nHost: x\r\n\r\n",
            ]
        )
    }

    func testMiddlewareEquivalence() throws {
        let fixture = EquivalenceFixture(
            hasMiddleware: true
        )

        try fixture.writeBoth(
            "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
        )
        try fixture.assertEqual()
        XCTAssertTrue(fixture.stockChannel.isActive)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testSplitHeadAcrossReads() throws {
        try assertEquivalent(
            writes: [
                "GET / HTTP/1.1\r\nHo",
                "st: x\r\n\r",
                "\n",
            ]
        )
    }

    func testTier1StreamingRoute500WithoutInvoking() throws {
        let fixture = EquivalenceFixture(
            hasStreamingRoutes: true
        )

        XCTAssertEqual(
            fixture.streamingBeginCount,
            0
        )
        try fixture.tier1Channel.writeInbound(
            fixture.inboundBuffer(
                "POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
            )
        )
        fixture.tier1Loop.run()

        let bytes = try fixture.readTier1()
        let text = String(
            decoding: bytes,
            as: UTF8.self
        )
        XCTAssertTrue(
            text.hasPrefix(
                "HTTP/1.1 500 Internal Server Error\r\n"
            ),
            text
        )
        XCTAssertTrue(
            text.hasSuffix("Internal Server Error"),
            text
        )
        XCTAssertEqual(
            fixture.streamingBeginCount,
            0
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testTier1StreamingOverLimit413() throws {
        let fixture = EquivalenceFixture(
            maxBodyBytes: 4,
            hasStreamingRoutes: true
        )

        try fixture.tier1Channel.writeInbound(
            fixture.inboundBuffer(
                "POST /stream HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
            )
        )
        fixture.tier1Loop.run()

        let bytes = try fixture.readTier1()
        let text = String(
            decoding: bytes,
            as: UTF8.self
        )
        XCTAssertTrue(
            text.hasPrefix(
                "HTTP/1.1 413 Payload Too Large\r\n"
            ),
            text
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testTier1FileRegion500() throws {
        let fixture = EquivalenceFixture()

        try fixture.tier1Channel.writeInbound(
            fixture.inboundBuffer(
                "GET /file HTTP/1.1\r\nHost: x\r\n\r\n"
            )
        )
        fixture.tier1Loop.run()

        let bytes = try fixture.readTier1()
        let text = String(
            decoding: bytes,
            as: UTF8.self
        )
        XCTAssertTrue(
            text.hasPrefix(
                "HTTP/1.1 500 Internal Server Error\r\n"
            ),
            text
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testTier1StreamBody500WithoutProducing() throws {
        let fixture = EquivalenceFixture()

        try fixture.tier1Channel.writeInbound(
            fixture.inboundBuffer(
                "GET /stream-body HTTP/1.1\r\nHost: x\r\n\r\n"
            )
        )
        fixture.tier1Loop.run()

        let bytes = try fixture.readTier1()
        let text = String(
            decoding: bytes,
            as: UTF8.self
        )
        XCTAssertTrue(
            text.hasPrefix(
                "HTTP/1.1 500 Internal Server Error\r\n"
            ),
            text
        )
        XCTAssertEqual(
            fixture.streamProduceCount,
            0
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    private func assertEquivalent(
        writes: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = EquivalenceFixture()

        for write in writes {
            try fixture.writeBoth(write)
        }

        try fixture.assertEqual(
            file: file,
            line: line
        )
        XCTAssertTrue(
            fixture.stockChannel.isActive,
            file: file,
            line: line
        )
        XCTAssertTrue(
            fixture.tier1Channel.isActive,
            file: file,
            line: line
        )
    }
}

private final class EquivalenceCounter:
    @unchecked Sendable
{
    var value = 0
}

private final class EquivalenceFixture {
    let stockLoop = EmbeddedEventLoop()
    let tier1Loop = EmbeddedEventLoop()
    let stockChannel: EmbeddedChannel
    let tier1Channel: EmbeddedChannel

    private let asyncPromise:
        EventLoopPromise<RuntimeResponse>
    private var asyncCompleted = false
    private let streamingBegins =
        EquivalenceCounter()
    private let streamProduces =
        EquivalenceCounter()
    private let fileHandle: NIOFileHandle?

    deinit {
        // Embedded promises trap on deinit when never completed.
        if !asyncCompleted {
            asyncPromise.succeed(Self.text("unused"))
        }

        try? fileHandle?.close()
    }

    var streamingBeginCount: Int {
        streamingBegins.value
    }

    var streamProduceCount: Int {
        streamProduces.value
    }

    init(
        maxBodyBytes: Int = 1_048_576,
        hasMiddleware: Bool = false,
        hasStreamingRoutes: Bool = false
    ) {
        stockChannel = EmbeddedChannel(
            loop: stockLoop
        )
        tier1Channel = EmbeddedChannel(
            loop: tier1Loop
        )
        asyncPromise = stockLoop.makePromise(
            of: RuntimeResponse.self
        )

        let hello = RuntimeSyncAction { _ in
            Self.text("hello")
        }
        let preparedHello = Self.fixed(
            status: .ok,
            body: "prepared-body"
        )
        let streamingBegins = streamingBegins
        let streamProduces = streamProduces
        let asyncPromise = asyncPromise
        let produceLoop = stockLoop
        let fileHandle = try! NIOFileHandle(
            path: "/dev/null",
            mode: .read
        )
        self.fileHandle = fileHandle

        var routes: [String: RuntimeRouteAction] = [
            "GET /": .sync(hello),
            "HEAD /": .sync(hello),
            "CONNECT /": .sync(hello),
            "GET /prep": .prepared(preparedHello),
            "HEAD /prep": .prepared(preparedHello),
            "GET /ws": .sync(
                RuntimeSyncAction { _ in
                    Self.text("ws")
                }
            ),
            "POST /echo": .sync(
                RuntimeSyncAction { request in
                    let body = request.body
                    let length = body.readableBytes
                    var headers = HTTPHeaders()
                    headers.add(
                        name: "content-type",
                        value:
                            "text/plain; charset=utf-8"
                    )
                    headers.add(
                        name: "content-length",
                        value: String(length)
                    )
                    return RuntimeResponse(
                        status: .ok,
                        headers: headers,
                        body: .buffer(body),
                        contentLengthIsNormalized:
                            true
                    )
                }
            ),
            "GET /async": .async(
                RuntimeAsyncAction { _, _ in
                    asyncPromise.futureResult
                }
            ),
            "GET /fail": .async(
                RuntimeAsyncAction { _, eventLoop in
                    eventLoop.makeFailedFuture(
                        FixtureFailure.route
                    )
                }
            ),
            "GET /notmodified": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .notModified,
                        headers: HTTPHeaders([
                            (
                                "content-length",
                                "5"
                            ),
                            ("etag", "\"x\""),
                        ]),
                        body: .empty
                    )
                }
            ),
            "GET /nocontent": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .noContent,
                        headers: HTTPHeaders([
                            (
                                "content-length",
                                "5"
                            )
                        ]),
                        body: .empty
                    )
                }
            ),
            "GET /nocl": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders([
                            (
                                "content-type",
                                "text/plain"
                            )
                        ]),
                        body: .text("repair-me")
                    )
                }
            ),
            "GET /file": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .fileRegion(
                            FileRegion(
                                fileHandle: fileHandle,
                                readerIndex: 0,
                                endIndex: 0
                            )
                        )
                    )
                }
            ),
            "GET /stream-body": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .stream(
                            RuntimeResponseStream(
                                produce: {
                                    _ in
                                    streamProduces
                                        .value += 1
                                    return produceLoop
                                        .makeSucceededFuture(
                                            ()
                                        )
                                }
                            )
                        )
                    )
                }
            ),
        ]

        if hasStreamingRoutes {
            routes["POST /stream"] = .streaming(
                RuntimeStreamingAction(
                    begin: { _, _ in
                        streamingBegins.value += 1
                        return nil
                    },
                    runAggregated: { _, _ in
                        .response(Self.text("agg"))
                    }
                )
            )
        }

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
                    Self.fixed(
                        status: .notFound,
                        body: "Not Found"
                    )
                )
            },
            dispatchPipeline: { request, _ in
                .response(
                    Self.text(
                        "mw:\(request.head.uri)"
                    )
                )
            },
            mapError: { _, _, _ in
                .response(
                    Self.text(
                        "Mapped Error",
                        status: .internalServerError
                    )
                )
            },
            notFound: Self.fixed(
                status: .notFound,
                body: "Not Found"
            ),
            payloadTooLarge: Self.fixed(
                status: .payloadTooLarge,
                body: "Payload Too Large"
            ),
            expectationFailed: Self.fixed(
                status: .expectationFailed,
                body: "Expectation Failed"
            ),
            internalServerError: Self.fixed(
                status: .internalServerError,
                body: "Internal Server Error"
            )
        )

        let configuration =
            RuntimeServerConfiguration(
                maxRequestBodyBytes: maxBodyBytes
            )

        let configured = stockChannel.pipeline
            .configureHTTPServerPipeline(
                withPipeliningAssistance: true,
                withErrorHandling: true
            )
        stockLoop.run()
        try! configured.wait()
        try! stockChannel.pipeline.syncOperations
            .addHandler(
                RuntimeConnectionHandler(
                    dispatcher: dispatcher,
                    configuration: configuration
                )
            )
        try! tier1Channel.pipeline.syncOperations
            .addHandler(
                WTHTTP1ConnectionHandler(
                    dispatcher: dispatcher,
                    configuration: configuration
                )
            )
        try! stockChannel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()
        try! tier1Channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()
    }

    func succeedAsync(
        value: String
    ) {
        asyncCompleted = true
        asyncPromise.succeed(Self.text(value))
        stockLoop.run()
        tier1Loop.run()
        stockLoop.run()
        tier1Loop.run()
    }

    func driveLoops() {
        stockLoop.run()
        tier1Loop.run()
        stockLoop.run()
        tier1Loop.run()
    }

    func writeBoth(
        _ string: String,
        runLoops: Bool = true
    ) throws {
        try writeBoth(
            bytes: Array(string.utf8),
            runLoops: runLoops
        )
    }

    func writeBoth(
        bytes: [UInt8],
        runLoops: Bool = true
    ) throws {
        try stockChannel.writeInbound(
            inboundBuffer(bytes: bytes)
        )
        try tier1Channel.writeInbound(
            inboundBuffer(bytes: bytes)
        )

        if runLoops {
            driveLoops()
        }
    }

    func inboundBuffer(
        _ string: String
    ) -> ByteBuffer {
        inboundBuffer(bytes: Array(string.utf8))
    }

    func inboundBuffer(
        bytes: [UInt8]
    ) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(
            capacity: bytes.count
        )
        buffer.writeBytes(bytes)
        return buffer
    }

    func readStock() throws -> [UInt8] {
        stockLoop.run()

        var out: [UInt8] = []

        while let chunk = try stockChannel
            .readOutbound(as: ByteBuffer.self)
        {
            out += chunk.readableBytesView
        }

        return out
    }

    func readTier1() throws -> [UInt8] {
        tier1Loop.run()

        var out: [UInt8] = []

        while let chunk = try tier1Channel
            .readOutbound(as: ByteBuffer.self)
        {
            out += chunk.readableBytesView
        }

        return out
    }

    func assertEqual(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let stock = try readStock()
        let tier1 = try readTier1()

        XCTAssertEqual(
            stock,
            tier1,
            """
            stock=\(String(decoding: stock, as: UTF8.self).debugDescription) \
            tier1=\(String(decoding: tier1, as: UTF8.self).debugDescription)
            """,
            file: file,
            line: line
        )
    }

    /// Stock emitted exactly the Tier 1 bytes plus one trailing
    /// post-close 400. Used only where the test documents why the
    /// embedded channel captures a 400 that a real socket drops.
    func assertEqualAllowingStockPostClose400(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let stock = try readStock()
        let tier1 = try readTier1()
        let artifact = Array(
            "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                .utf8
        )

        XCTAssertEqual(
            stock,
            tier1 + artifact,
            """
            stock=\(String(decoding: stock, as: UTF8.self).debugDescription) \
            tier1=\(String(decoding: tier1, as: UTF8.self).debugDescription)
            """,
            file: file,
            line: line
        )
    }

    static func text(
        _ value: String,
        status: HTTPResponseStatus = .ok
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
            status: status,
            headers: headers,
            body: .text(value),
            contentLengthIsNormalized: true
        )
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
}

private enum FixtureFailure: Error {
    case route
}
