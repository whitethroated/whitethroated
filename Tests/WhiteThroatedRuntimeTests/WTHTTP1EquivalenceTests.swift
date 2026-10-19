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
/// handler; Tier 1: the single custom handler) and requires
/// identical outbound bytes plus identical channel-active state.
/// Request-streaming routes are tested directly as unsupported by this
/// handler; the server selects the stock transport for those applications.
/// File regions and response streams have equivalence coverage below.
final class WTHTTP1EquivalenceTests: XCTestCase {
    func testPendingAsyncDefersFollowerAndSocketReads() throws {
        let fixture = EquivalenceFixture()
        let probe = EquivalenceReadProbe()
        try fixture.tier1Channel.pipeline.syncOperations.addHandler(probe, position: .first)
        try fixture.writeBoth(
            "GET /async HTTP/1.1\r\nHost: x\r\n\r\n"
                + "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        XCTAssertEqual(fixture.ordinaryRunCount, 0)
        fixture.tier1Channel.read()
        XCTAssertEqual(probe.reads, 0)
        fixture.succeedAsync(value: "late")
        XCTAssertEqual(fixture.ordinaryRunCount, 2)
        XCTAssertEqual(probe.reads, 1)
        try fixture.assertEqual()
    }

    func testOpenStreamDefersFollowerAndSocketReads() throws {
        let fixture = EquivalenceFixture()
        let probe = EquivalenceReadProbe()
        try fixture.tier1Channel.pipeline.syncOperations.addHandler(probe, position: .first)
        try fixture.writeBoth(
            "GET /stream-slow HTTP/1.1\r\nHost: x\r\n\r\n"
                + "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        XCTAssertEqual(fixture.ordinaryRunCount, 0)
        fixture.tier1Channel.read()
        XCTAssertEqual(probe.reads, 0)
        try fixture.assertEqual()
        fixture.completeSlowStream()
        XCTAssertEqual(fixture.ordinaryRunCount, 2)
        XCTAssertEqual(probe.reads, 1)
        try fixture.assertEqual()
    }

    func testRequestBodyStillAllowsSocketReads() throws {
        let fixture = EquivalenceFixture()
        let probe = EquivalenceReadProbe()
        try fixture.tier1Channel.pipeline.syncOperations.addHandler(probe, position: .first)
        try fixture.writeBoth(
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhe"
        )
        fixture.tier1Channel.read()
        XCTAssertEqual(probe.reads, 1)
        try fixture.writeBoth("llo")
        try fixture.assertEqual()
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testDisconnectDropsPendingFollowerAndRead() throws {
        let fixture = EquivalenceFixture()
        let probe = EquivalenceReadProbe()
        try fixture.tier1Channel.pipeline.syncOperations.addHandler(probe, position: .first)
        try fixture.writeBoth(
            "GET /async HTTP/1.1\r\nHost: x\r\n\r\n"
                + "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        fixture.tier1Channel.read()
        try fixture.stockChannel.close().wait()
        try fixture.tier1Channel.close().wait()
        fixture.succeedAsync(value: "late")
        XCTAssertEqual(fixture.ordinaryRunCount, 0)
        XCTAssertEqual(probe.reads, 0)
        try fixture.assertEqual()
    }

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

    func testDecodedHeadersKeepOrderCaseEmptyValuesAndRefreshOnCacheHit() throws {
        try assertEquivalent(writes: [
            "GET /inspect-headers HTTP/1.1\r\nHost: x\r\nX-Case: café\r\nX-Empty:\r\nX-Case: second\r\n\r\n",
            "GET /inspect-headers HTTP/1.1\r\nHost: y\r\nx-case: changed\r\nX-Empty: now set\r\n\r\n",
            "GET /inspect-headers HTTP/1.1\r\nHost: z\r\n\r\n",
        ])
    }

    func testPreparedTwice() throws {
        try assertEquivalent(
            writes: [
                "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
                "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
            ]
        )
    }

    func testPreparedCacheHitRetainsFallbackAndIdentitySemantics() throws {
        try assertEquivalent(writes: [
            "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET /prep HTTP/1.1\r\n\r\n",
            "GET /prep HTTP/1.1\r\nHoSt: other\r\n\r\n",
            "HEAD /prep HTTP/1.1\r\nHost: x\r\n\r\n",
            "HEAD /prep HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET /prep?query=1 HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET /prep HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc",
            "GET /prep HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "GET /prep HTTP/1.0\r\nConnection: keep-alive\r\n\r\n",
            "GET /prep HTTP/1.1\r\nHost: x\r\nX-Extra: value\r\n\r\n",
            "GET /prep HTTP/1.1\r\nHost: x\r\n\r\n",
        ])
    }

    func testPreparedCacheHitDoesNotIgnoreConnectionClose() throws {
        let fixture = EquivalenceFixture()
        try fixture.writeBoth("GET /prep HTTP/1.1\r\nHost: x\r\n\r\n")
        try fixture.assertEqual()
        try fixture.writeBoth("GET /prep HTTP/1.1\r\nHost: x\r\n\r\n")
        try fixture.assertEqual()
        try fixture.writeBoth("GET /prep HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        try fixture.assertEqual()
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
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

    func testFileRegionEquivalent() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /file HTTP/1.1\r\nHost: x\r\n\r\n"
        )

        XCTAssertEqual(
            try fixture.readStockIO(),
            try fixture.readTier1IO()
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testFileRegionContentEquivalent() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /file-content HTTP/1.1\r\nHost: x\r\n\r\n"
        )

        let stock = try fixture.readStockIO()
        let tier1 = try fixture.readTier1IO()

        XCTAssertEqual(stock, tier1)
        // Zero-copy preserved: a region (not inlined bytes)
        // crosses on both transports.
        XCTAssertEqual(stock.regions.count, 1)
        XCTAssertEqual(stock.regions.first?.reader, 16)
        XCTAssertEqual(stock.regions.first?.end, 4096)

        let head = String(
            decoding: stock.bytes,
            as: UTF8.self
        )
        XCTAssertTrue(
            head.contains("content-length: 4080\r\n"),
            head
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testFileRegionHeadSuppressesRegion() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "HEAD /file-content HTTP/1.1\r\nHost: x\r\n\r\n"
        )

        let stock = try fixture.readStockIO()
        let tier1 = try fixture.readTier1IO()

        XCTAssertEqual(stock, tier1)
        XCTAssertTrue(stock.regions.isEmpty)

        let head = String(
            decoding: stock.bytes,
            as: UTF8.self
        )
        XCTAssertTrue(
            head.contains("content-length: 4080\r\n"),
            head
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamBodyEquivalent() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-body HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "transfer-encoding: chunked\r\n\r\n"
                + "0\r\n\r\n"
        )
        // The producer runs on both transports now.
        XCTAssertEqual(fixture.streamProduceCount, 2)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamChunksEquivalent() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-chunks HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        // Empty fragments are skipped (framing one would end the
        // stream); lowercase hex lengths, shared terminal.
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "transfer-encoding: chunked\r\n\r\n"
                + "2\r\nab\r\n"
                + "3\r\ncde\r\n"
                + "0\r\n\r\n"
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamDeclaredLengthEquivalent() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-cl HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "content-length: 5\r\n\r\n"
                + "hello"
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamDeclaredLengthFastPath() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-cl-fast HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "content-type: text/plain\r\n"
                + "content-length: 5\r\n\r\n"
                + "hello"
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamLengthOverflowCloses() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-cl-over HTTP/1.1\r\nHost: x\r\n\r\n"
        )

        // The overflowing write emits nothing on either transport;
        // both heads match and both connections close.
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "content-length: 5\r\n\r\n"
        )
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
        XCTAssertEqual(
            fixture.streamErrorDescriptions.sorted(),
            [
                "contentLengthExceeded(expected: 5, attempted: 10)",
                "contentLengthExceeded(expected: 5, attempted: 10)",
            ]
        )
    }

    func testStreamLengthUnderflowCloses() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-cl-short HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "content-length: 5\r\n\r\n"
                + "hey"
        )
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
        XCTAssertEqual(
            fixture.streamErrorDescriptions.sorted(),
            [
                "contentLengthMismatch(expected: 5, actual: 3)",
                "contentLengthMismatch(expected: 5, actual: 3)",
            ]
        )
    }

    func testStreamProducerFailureCloses() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-fail HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        // Accepted bytes flush, then the connection closes with no
        // terminal (a terminal would lie about completeness).
        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "transfer-encoding: chunked\r\n\r\n"
                + "2\r\nab\r\n"
        )
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
        XCTAssertEqual(
            fixture.streamErrorDescriptions.sorted(),
            [
                "EquivalenceProbeError()",
                "EquivalenceProbeError()",
            ]
        )
    }

    func testStreamHeadSuppressesProducer() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "HEAD /stream-body HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        // Framing is advertised but nothing follows: no producer,
        // no chunks, no terminal.
        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "transfer-encoding: chunked\r\n\r\n"
        )
        XCTAssertEqual(fixture.streamProduceCount, 0)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamConnectSuppressesProducerTier1() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "CONNECT /stream-body HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        // Identical wire (stripped head only); only the producer
        // visibility differs (documented intentional divergence:
        // stock runs it into encoder drops, Tier 1 never starts it).
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(text, "HTTP/1.1 200 OK\r\n\r\n")
        XCTAssertEqual(fixture.streamProduceCount, 1)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamBodilessStatusSuppresses() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-204 HTTP/1.1\r\nHost: x\r\n\r\n"
        )

        // The bodiless guard sits above the stream branch on both
        // transports: a clean head, producer never started.
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 204 No Content\r\n\r\n"
        )
        XCTAssertEqual(fixture.streamProduceCount, 0)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamInvalidLengthMapsError() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-bad-cl HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        // No head is written; the mapped error response flows on
        // both transports and the producer never runs.
        try fixture.assertEqual()
        XCTAssertEqual(fixture.streamProduceCount, 0)
        XCTAssertEqual(
            fixture.streamErrorDescriptions.sorted(),
            [
                "invalidContentLength(\"xyz\")",
                "invalidContentLength(\"xyz\")",
            ]
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamValidationGuardsDoNotAccumulateOnKeepAlive() throws {
        let fixture = EquivalenceFixture()
        let handler = try fixture.tier1Channel.pipeline.syncOperations
            .handler(type: WTHTTP1ConnectionHandler.self)
        for _ in 0..<32 {
            try fixture.writeBoth(
                "GET /stream-bad-cl HTTP/1.1\r\nHost: x\r\n\r\n"
            )
            try fixture.assertEqual()
            XCTAssertNil(handler.streamValidationFailed)
        }
        XCTAssertEqual(fixture.streamErrorDescriptions.count, 64)
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamValidationGuardSurvivesPendingForeignErrorFuture() throws {
        for outcome in 0..<3 {
            let errorLoop = EmbeddedEventLoop()
            let promise = errorLoop.makePromise(of: RuntimeResponse.self)
            let fixture = EquivalenceFixture(errorFuture: promise.futureResult)
            let handler = try fixture.tier1Channel.pipeline.syncOperations
                .handler(type: WTHTTP1ConnectionHandler.self)
            try fixture.tier1Channel.writeInbound(fixture.inboundBuffer(
                "GET /stream-bad-cl HTTP/1.1\r\nHost: x\r\n\r\n"
            ))
            fixture.tier1Loop.run()
            XCTAssertEqual(handler.streamValidationFailed?.count, 1)
            XCTAssertEqual(try fixture.readTier1(), [])
            switch outcome {
            case 0:
                promise.succeed(RuntimeResponse(
                    status: .ok, headers: HTTPHeaders(), body: .text("fixed")
                ))
            case 1:
                promise.succeed(RuntimeResponse(
                    status: .ok,
                    headers: HTTPHeaders([("content-length", "xyz")]),
                    body: .stream(RuntimeResponseStream(produce: { writer in
                        XCTFail("An invalid error stream must never produce")
                        return writer.eventLoop.makeSucceededVoidFuture()
                    }))
                ))
            default:
                promise.fail(EquivalenceProbeError())
            }
            errorLoop.run()
            fixture.tier1Loop.run()
            let response = String(decoding: try fixture.readTier1(), as: UTF8.self)
            XCTAssertTrue(response.contains(outcome == 0 ? "200 OK" : "500 Internal Server Error"))
            XCTAssertNil(handler.streamValidationFailed)
            XCTAssertTrue(fixture.tier1Channel.isActive)
        }
    }

    func testStreamAmbiguousLengthMapsError() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-amb-cl HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        try fixture.assertEqual()
        XCTAssertEqual(fixture.streamProduceCount, 0)
        // One comma-joined line stays one value; both
        // transports map it through the same helper.
        XCTAssertEqual(
            fixture.streamErrorDescriptions.sorted(),
            [
                "ambiguousContentLength([\"5, 5\"])",
                "ambiguousContentLength([\"5, 5\"])",
            ]
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamRegionEquivalent() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-region HTTP/1.1\r\nHost: x\r\n\r\n"
        )

        let stock = try fixture.readStockIO()
        let tier1 = try fixture.readTier1IO()

        XCTAssertEqual(stock, tier1)
        XCTAssertEqual(stock.regions.count, 1)
        XCTAssertEqual(stock.regions.first?.reader, 16)
        XCTAssertEqual(stock.regions.first?.end, 4096)

        let text = String(
            decoding: stock.bytes,
            as: UTF8.self
        )
        XCTAssertTrue(
            text.hasPrefix(
                "HTTP/1.1 200 OK\r\n"
                    + "transfer-encoding: chunked\r\n\r\n"
                    + "ff0\r\n"
            ),
            text
        )
        XCTAssertTrue(
            text.hasSuffix("\r\n0\r\n\r\n"),
            text
        )
        XCTAssertTrue(fixture.tier1Channel.isActive)
    }

    func testStreamPipelinedAfterSlowAsync() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /async HTTP/1.1\r\nHost: x\r\n\r\n"
                + "GET /stream-chunks HTTP/1.1\r\nHost: x\r\n\r\n",
            runLoops: false
        )
        fixture.driveLoops()

        // The async response is pending, so the stream head is held
        // on both transports: nothing on the wire yet.
        XCTAssertEqual(try fixture.readStock(), [])
        XCTAssertEqual(try fixture.readTier1(), [])

        fixture.succeedAsync(value: "late")
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.1 200 OK\r\n"
                + "content-type: text/plain; charset=utf-8\r\n"
                + "content-length: 4\r\n\r\n"
                + "late"
                + "HTTP/1.1 200 OK\r\n"
                + "transfer-encoding: chunked\r\n\r\n"
                + "2\r\nab\r\n"
                + "3\r\ncde\r\n"
                + "0\r\n\r\n"
        )
    }

    func testStreamGatesPipelinedFollower() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-slow HTTP/1.1\r\nHost: x\r\n\r\n"
                + "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
            runLoops: false
        )
        fixture.driveLoops()

        // The follower is held behind the open stream on both
        // transports: head plus the first chunk only.
        let partial =
            "HTTP/1.1 200 OK\r\n"
            + "transfer-encoding: chunked\r\n\r\n"
            + "1\r\na\r\n"
        XCTAssertEqual(
            String(
                decoding: try fixture.readStock(),
                as: UTF8.self
            ),
            partial
        )
        XCTAssertEqual(
            String(
                decoding: try fixture.readTier1(),
                as: UTF8.self
            ),
            partial
        )

        fixture.completeSlowStream()
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "0\r\n\r\n"
                + "HTTP/1.1 200 OK\r\n"
                + "content-type: text/plain; charset=utf-8\r\n"
                + "content-length: 5\r\n\r\n"
                + "hello"
        )
    }

    func testStreamHeldHeadGatesFollower() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /async HTTP/1.1\r\nHost: x\r\n\r\n"
                + "GET /stream-slow HTTP/1.1\r\nHost: x\r\n\r\n"
                + "GET / HTTP/1.1\r\nHost: x\r\n\r\n",
            runLoops: false
        )
        fixture.driveLoops()

        // The slow stream head is held behind the pending async
        // response on both transports: nothing on the wire and the
        // producer has not started on either.
        XCTAssertEqual(try fixture.readStock(), [])
        XCTAssertEqual(try fixture.readTier1(), [])
        XCTAssertEqual(fixture.streamProduceCount, 0)

        fixture.succeedAsync(value: "late")

        // The async bytes move, the stream head releases with its
        // flushed first chunk, and the follower stays held behind
        // the open stream.
        let partial =
            "HTTP/1.1 200 OK\r\n"
            + "content-type: text/plain; charset=utf-8\r\n"
            + "content-length: 4\r\n\r\n"
            + "late"
            + "HTTP/1.1 200 OK\r\n"
            + "transfer-encoding: chunked\r\n\r\n"
            + "1\r\na\r\n"
        XCTAssertEqual(
            String(
                decoding: try fixture.readStock(),
                as: UTF8.self
            ),
            partial
        )
        XCTAssertEqual(
            String(
                decoding: try fixture.readTier1(),
                as: UTF8.self
            ),
            partial
        )
        XCTAssertEqual(fixture.streamProduceCount, 2)

        fixture.completeSlowStream()
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "0\r\n\r\n"
                + "HTTP/1.1 200 OK\r\n"
                + "content-type: text/plain; charset=utf-8\r\n"
                + "content-length: 5\r\n\r\n"
                + "hello"
        )
    }

    func testStreamHTTP10UnknownCloses() throws {
        let fixture = EquivalenceFixture()

        try fixture.writeBoth(
            "GET /stream-body HTTP/1.0\r\n\r\n"
        )
        // Unknown length on HTTP/1.0 is close-delimited (no
        // Transfer-Encoding); the end closes the connection.
        let stock = try fixture.readStock()
        let tier1 = try fixture.readTier1()

        XCTAssertEqual(stock, tier1)

        let text = String(
            decoding: tier1,
            as: UTF8.self
        )
        XCTAssertEqual(
            text,
            "HTTP/1.0 200 OK\r\n"
                + "connection: close\r\n\r\n"
        )
        XCTAssertFalse(fixture.stockChannel.isActive)
        XCTAssertFalse(fixture.tier1Channel.isActive)
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

private final class EquivalenceStrings:
    @unchecked Sendable
{
    var values: [String] = []
}

private struct EquivalenceProbeError: Error {}

private final class EquivalenceReadProbe: ChannelOutboundHandler {
    typealias OutboundIn = IOData
    var reads = 0

    func read(context: ChannelHandlerContext) {
        reads += 1
        context.read()
    }
}

private final class EquivalenceFixture {
    let stockLoop = EmbeddedEventLoop()
    let tier1Loop = EmbeddedEventLoop()
    let stockChannel: EmbeddedChannel
    let tier1Channel: EmbeddedChannel

    private let asyncPromise:
        EventLoopPromise<RuntimeResponse>
    private var asyncCompleted = false
    private let slowStreamPromise:
        EventLoopPromise<Void>
    private var slowStreamCompleted = false
    private let streamingBegins =
        EquivalenceCounter()
    private let ordinaryRuns = EquivalenceCounter()
    private let streamProduces =
        EquivalenceCounter()
    private let streamErrors =
        EquivalenceCounter()
    private let streamErrorBox =
        EquivalenceStrings()
    private let fileHandle: NIOFileHandle?
    private let contentHandle: NIOFileHandle?

    deinit {
        // Embedded promises trap on deinit when never completed.
        if !asyncCompleted {
            asyncPromise.succeed(Self.text("unused"))
        }

        if !slowStreamCompleted {
            slowStreamPromise.succeed(())
        }

        try? fileHandle?.close()
        try? contentHandle?.close()
    }

    var streamingBeginCount: Int {
        streamingBegins.value
    }

    var ordinaryRunCount: Int {
        ordinaryRuns.value
    }

    var streamProduceCount: Int {
        streamProduces.value
    }

    var streamErrorDescriptions: [String] {
        streamErrorBox.values
    }

    init(
        maxBodyBytes: Int = 1_048_576,
        hasMiddleware: Bool = false,
        hasStreamingRoutes: Bool = false,
        errorFuture: EventLoopFuture<RuntimeResponse>? = nil
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
        slowStreamPromise = stockLoop.makePromise(
            of: Void.self
        )

        let ordinaryRuns = ordinaryRuns
        let hello = RuntimeSyncAction { _ in
            ordinaryRuns.value += 1
            return Self.text("hello")
        }
        let preparedHello = Self.fixed(
            status: .ok,
            body: "prepared-body"
        )
        let streamingBegins = streamingBegins
        let streamProduces = streamProduces
        let streamErrors = streamErrors
        let streamErrorBox = streamErrorBox
        let asyncPromise = asyncPromise
        let slowStreamPromise = slowStreamPromise
        let produceLoop = stockLoop

        let recordStreamError:
            @Sendable (Error) -> Void =
            { error in
                streamErrors.value += 1
                streamErrorBox.values.append(
                    String(describing: error)
                )
            }
        let fileHandle = try! NIOFileHandle(
            path: "/dev/null",
            mode: .read
        )
        self.fileHandle = fileHandle

        let contentHandle = try! NIOFileHandle(
            path: "/dev/urandom",
            mode: .read
        )
        self.contentHandle = contentHandle

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
            "GET /inspect-headers": .sync(
                RuntimeSyncAction { request in
                    Self.text(request.head.headers.map { "\($0.name)=\($0.value)" }.joined(separator: "|"))
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
            "GET /file-content": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .fileRegion(
                            FileRegion(
                                fileHandle: contentHandle,
                                readerIndex: 16,
                                endIndex: 4096
                            )
                        )
                    )
                }
            ),
            "HEAD /file-content": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .fileRegion(
                            FileRegion(
                                fileHandle: contentHandle,
                                readerIndex: 16,
                                endIndex: 4096
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
            "HEAD /stream-body": .sync(
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
            "CONNECT /stream-body": .sync(
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
            "GET /stream-chunks": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeString("ab")
                                    writer.writeString("")
                                    writer.writeStringAndFlush(
                                        "cde"
                                    )
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
                                }
                            )
                        )
                    )
                }
            ),
            "GET /stream-cl": .sync(
                RuntimeSyncAction { _ in
                    var headers = HTTPHeaders()
                    headers.add(
                        name: "content-length",
                        value: "5"
                    )
                    return RuntimeResponse(
                        status: .ok,
                        headers: headers,
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeString("hello")
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
                                }
                            )
                        )
                    )
                }
            ),
            "GET /stream-cl-fast": .sync(
                RuntimeSyncAction { _ in
                    var headers = HTTPHeaders()
                    headers.add(
                        name: "content-type",
                        value: "text/plain"
                    )
                    headers.add(
                        name: "content-length",
                        value: "5"
                    )
                    return RuntimeResponse(
                        status: .ok,
                        headers: headers,
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeString("he")
                                    writer.writeString("llo")
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
                                },
                                expectedContentLength: 5
                            )
                        ),
                        contentLengthIsNormalized: true
                    )
                }
            ),
            "GET /stream-cl-over": .sync(
                RuntimeSyncAction { _ in
                    var headers = HTTPHeaders()
                    headers.add(
                        name: "content-length",
                        value: "5"
                    )
                    return RuntimeResponse(
                        status: .ok,
                        headers: headers,
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    // The write fails (nothing
                                    // emitted); observing the
                                    // failure and succeeding anyway
                                    // surfaces the recorded
                                    // overflow at completion.
                                    return writer.writeString(
                                        "toolong!!!"
                                    ).flatMapError { _ in
                                        writer.eventLoop
                                            .makeSucceededVoidFuture()
                                    }
                                },
                                onError: recordStreamError
                            )
                        )
                    )
                }
            ),
            "GET /stream-cl-short": .sync(
                RuntimeSyncAction { _ in
                    var headers = HTTPHeaders()
                    headers.add(
                        name: "content-length",
                        value: "5"
                    )
                    return RuntimeResponse(
                        status: .ok,
                        headers: headers,
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeString("hey")
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
                                },
                                onError: recordStreamError
                            )
                        )
                    )
                }
            ),
            "GET /stream-fail": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeString("ab")
                                    return writer.eventLoop
                                        .makeFailedFuture(
                                            EquivalenceProbeError()
                                        )
                                },
                                onError: recordStreamError
                            )
                        )
                    )
                }
            ),
            "GET /stream-slow": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeStringAndFlush(
                                        "a"
                                    )
                                    return slowStreamPromise
                                        .futureResult
                                }
                            )
                        )
                    )
                }
            ),
            "GET /stream-region": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .ok,
                        headers: HTTPHeaders(),
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeFileRegion(
                                        FileRegion(
                                            fileHandle:
                                                contentHandle,
                                            readerIndex: 16,
                                            endIndex: 4096
                                        )
                                    )
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
                                }
                            )
                        )
                    )
                }
            ),
            "GET /stream-bad-cl": .sync(
                RuntimeSyncAction { _ in
                    var headers = HTTPHeaders()
                    headers.add(
                        name: "content-length",
                        value: "xyz"
                    )
                    return RuntimeResponse(
                        status: .ok,
                        headers: headers,
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
                                },
                                onError: recordStreamError
                            )
                        )
                    )
                }
            ),
            "GET /stream-amb-cl": .sync(
                RuntimeSyncAction { _ in
                    var headers = HTTPHeaders()
                    headers.add(
                        name: "content-length",
                        value: "5, 5"
                    )
                    return RuntimeResponse(
                        status: .ok,
                        headers: headers,
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
                                },
                                onError: recordStreamError
                            )
                        )
                    )
                }
            ),
            "GET /stream-204": .sync(
                RuntimeSyncAction { _ in
                    RuntimeResponse(
                        status: .noContent,
                        headers: HTTPHeaders(),
                        body: .stream(
                            RuntimeResponseStream(
                                produce: { writer in
                                    streamProduces
                                        .value += 1
                                    writer.writeString("x")
                                    return writer.eventLoop
                                        .makeSucceededVoidFuture()
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
                if let errorFuture { return .future(errorFuture) }
                return .response(
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

    func completeSlowStream() {
        slowStreamCompleted = true
        slowStreamPromise.succeed(())
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

    struct OutboundIO: Equatable {
        var bytes: [UInt8] = []
        var regions: [(reader: Int, end: Int)] = []

        static func == (
            left: OutboundIO,
            right: OutboundIO
        ) -> Bool {
            guard left.bytes == right.bytes else {
                return false
            }

            guard left.regions.count == right.regions.count
            else {
                return false
            }

            for (l, r) in zip(
                left.regions,
                right.regions
            ) {
                guard l.reader == r.reader && l.end == r.end
                else {
                    return false
                }
            }

            return true
        }
    }

    func readStockIO() throws -> OutboundIO {
        stockLoop.run()

        var out = OutboundIO()

        while let data = try stockChannel
            .readOutbound(as: IOData.self)
        {
            switch data {
            case .byteBuffer(let chunk):
                out.bytes += chunk.readableBytesView

            case .fileRegion(let region):
                out.regions.append((
                    reader: region.readerIndex,
                    end: region.endIndex
                ))
            }
        }

        return out
    }

    func readTier1IO() throws -> OutboundIO {
        tier1Loop.run()

        var out = OutboundIO()

        while let data = try tier1Channel
            .readOutbound(as: IOData.self)
        {
            switch data {
            case .byteBuffer(let chunk):
                out.bytes += chunk.readableBytesView

            case .fileRegion(let region):
                out.regions.append((
                    reader: region.readerIndex,
                    end: region.endIndex
                ))
            }
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
