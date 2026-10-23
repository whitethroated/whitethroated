import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest

@testable import WhiteThroatedRuntime

/// Exercise the same pipeline installer as accepted production connections.
final class RuntimeServerPipelineTests: XCTestCase {
    func testAcceptedSocketEnablesTCPNoDelayFromDisabledState() throws {
        let empty = RuntimePreparedResponse(status: .ok, headers: HTTPHeaders(), bodyBuffer: nil)
        let dispatcher = RuntimeDispatcher(
            hasMiddleware: false,
            hasStreamingRoutes: false,
            hasStreamingRoute: { _ in false },
            lookup: { _ in .prepared(empty) },
            dispatchPipeline: { _, _ in .response(empty.response) },
            mapError: { _, _, _ in .response(empty.response) },
            notFound: empty,
            payloadTooLarge: empty,
            expectationFailed: empty,
            internalServerError: empty
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let observed = group.next().makePromise(
            of: ChannelOptions.Types.SocketOption.Value.self
        )
        let server = try ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 0)
            .childChannelInitializer { channel in
                RuntimeServer.configureAcceptedChannel(
                    channel: channel,
                    dispatcher: dispatcher,
                    configuration: RuntimeServerConfiguration()
                ).flatMap {
                    channel.getOption(
                        ChannelOptions.tcpOption(.tcp_nodelay)
                    )
                }.map { value in
                    observed.succeed(value)
                }.flatMapError { error in
                    observed.fail(error)
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let port = try XCTUnwrap(server.localAddress?.port)
        let client = try ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: port).wait()
        defer { try? client.close().wait() }
        XCTAssertNotEqual(
            Int(try observed.futureResult.wait()),
            0
        )
    }

    func testHTTP1PipelineBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["WHITETHROATED_HTTP1_BENCHMARK"] == "1",
            "Set WHITETHROATED_HTTP1_BENCHMARK=1 to run the pipeline diagnostic."
        )
        let iterations = Int(environment["WHITETHROATED_HTTP1_ITERATIONS"] ?? "20000") ?? 20_000
        precondition(iterations > 0)
        let extraHeaders = Int(environment["WHITETHROATED_HTTP1_EXTRA_HEADERS"] ?? "0") ?? 0
        precondition((0...32).contains(extraHeaders))
        var requestText = "GET / HTTP/1.1\r\nHost: x\r\n"
        for index in 0..<extraHeaders {
            requestText += "X-Diagnostic-\(index): value-\(index)-café\r\n"
        }
        requestText += "\r\n"
        let request = ByteBuffer(string: requestText)
        for mode in ["prepared", "sync", "canonical", "stream"] {
            let fixtures = try [false, true].map {
                try PipelineFixture(
                    useTier1: $0,
                    streamingResponse: mode == "stream",
                    canonicalResponse: mode == "canonical",
                    preparedResponse: mode == "prepared"
                )
            }
            defer { for fixture in fixtures { _ = try? fixture.channel.finish() } }
            for fixture in fixtures {
                try fixture.write(requestText)
            }
            XCTAssertEqual(try fixtures[0].read(), try fixtures[1].read())
            var samples = [[Double](), [Double]()]
            var checksum = 0
            func step(_ fixture: PipelineFixture) throws {
                try fixture.channel.writeInbound(request)
                fixture.loop.run()
                while let data = try fixture.channel.readOutbound(as: IOData.self) {
                    checksum &+= data.readableBytes
                }
            }
            for fixture in fixtures {
                for _ in 0..<1000 { try step(fixture) }
            }
            for round in 0..<6 {
                for index in round.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<iterations { try step(fixtures[index]) }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    samples[index].append(Double(elapsed) / Double(iterations))
                }
            }
            for index in fixtures.indices {
                let sorted = samples[index].sorted()
                let median = (sorted[2] + sorted[3]) / 2
                print(
                    "http1-pipeline mode=\(mode) transport=\(index == 0 ? "stock" : "tier1") median_ns=\(median) rounds_ns=\(samples[index]) checksum=\(checksum) extra_headers=\(extraHeaders)"
                )
            }
        }
    }

    func testDefaultInstallsTier1AndServesKeepAlive() throws {
        XCTAssertTrue(RuntimeServerConfiguration().useTier1HTTP1)
        let fixture = try PipelineFixture()
        defer { _ = try? fixture.channel.finish() }

        XCTAssertNoThrow(
            try fixture.channel.pipeline.syncOperations
                .handler(type: WTHTTP1ConnectionHandler.self)
        )
        XCTAssertThrowsError(
            try fixture.channel.pipeline.syncOperations
                .handler(type: RuntimeConnectionHandler.self)
        )
        try fixture.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(try fixture.read().hasSuffix("ok"))
        try fixture.write("GET /other HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(try fixture.read().hasSuffix("ok"))
        XCTAssertEqual(fixture.state.ordinaryCalls, 2)
        XCTAssertTrue(fixture.channel.isActive)
    }

    func testExplicitStockOverride() throws {
        let fixture = try PipelineFixture(useTier1: false)
        defer { _ = try? fixture.channel.finish() }
        try fixture.assertStock()
        try fixture.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(try fixture.read().hasSuffix("ok"))
    }

    func testHTTPUpgradeForcesStockAndRemovesRuntimeHandler() throws {
        let loop = EmbeddedEventLoop()
        let channel =
            EmbeddedChannel(loop: loop)
        let empty =
            RuntimePreparedResponse(
                status: .ok,
                headers: HTTPHeaders(),
                bodyBuffer: nil
            )
        let dispatcher =
            RuntimeDispatcher(
                hasMiddleware: false,
                hasStreamingRoutes: false,
                hasStreamingRoute: {
                    _ in false
                },
                lookup: {
                    _ in
                    .prepared(empty)
                },
                dispatchPipeline: {
                    _, _ in
                    .response(empty.response)
                },
                mapError: {
                    _, _, _ in
                    .response(empty.response)
                },
                notFound: empty,
                payloadTooLarge: empty,
                expectationFailed: empty,
                internalServerError: empty
            )
        let state =
            UpgradeTestState()
        let upgrader =
            UpgradeTestUpgrader(
                state: state
            )
        let upgrade:
            NIOHTTPServerUpgradeSendableConfiguration =
                (
                    upgraders: [
                        upgrader,
                    ],
                    completionHandler: {
                        context in

                        state
                            .completionSawRuntimeHandler =
                            (
                                try? context
                                    .pipeline
                                    .syncOperations
                                    .handler(
                                        type:
                                            RuntimeConnectionHandler
                                                .self
                                    )
                            )
                            != nil
                    }
                )
        let configured =
            RuntimeServer
                .configureHTTPPipeline(
                    channel: channel,
                    dispatcher:
                        dispatcher,
                    configuration:
                        RuntimeServerConfiguration(
                            useTier1HTTP1:
                                true,
                            httpServerUpgrade:
                                upgrade
                        )
                )

        loop.run()
        try configured.wait()
        try channel.connect(
            to:
                SocketAddress(
                    ipAddress:
                        "127.0.0.1",
                    port: 1
                )
        )
        .wait()

        XCTAssertNoThrow(
            try channel.pipeline
                .syncOperations
                .handler(
                    type:
                        RuntimeConnectionHandler
                            .self
                )
        )
        XCTAssertThrowsError(
            try channel.pipeline
                .syncOperations
                .handler(
                    type:
                        WTHTTP1ConnectionHandler
                            .self
                )
        )

        try channel.writeInbound(
            ByteBuffer(
                string:
                    "GET /upgrade HTTP/1.1\r\n"
                    + "Host: x\r\n"
                    + "Connection: upgrade\r\n"
                    + "Upgrade: test\r\n"
                    + "\r\n"
            )
        )
        loop.run()

        XCTAssertTrue(
            state.upgraded
        )
        XCTAssertFalse(
            state
                .completionSawRuntimeHandler
        )
        XCTAssertThrowsError(
            try channel.pipeline
                .syncOperations
                .handler(
                    type:
                        RuntimeConnectionHandler
                            .self
                )
        )

        _ = try? channel.finish()
    }

    func testStreamingRegistrationSelectsStockForWholeConnection() throws {
        let fixture = try PipelineFixture(streaming: true)
        defer { _ = try? fixture.channel.finish() }
        try fixture.assertStock()

        // An ordinary request must work on the same connection before upload.
        try fixture.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(try fixture.read().hasSuffix("ok"))
        try fixture.write(
            "POST /upload HTTP/1.1\r\nHost: x\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n2\r\nab\r\n"
        )
        XCTAssertEqual(fixture.state.chunks, ["ab"])
        XCTAssertEqual(fixture.state.finishes, 0)
        XCTAssertEqual(try fixture.read(), "")
        try fixture.write("2\r\ncd\r\n0\r\n\r\n")
        XCTAssertTrue(try fixture.read().hasSuffix("uploaded"))
        XCTAssertEqual(fixture.state.chunks, ["ab", "cd"])
        XCTAssertEqual(fixture.state.finishes, 1)
        try fixture.write("GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
        XCTAssertTrue(try fixture.read().hasSuffix("ok"))
        XCTAssertTrue(fixture.channel.isActive)
    }

    func testStreamingFallbackPreservesBackpressure() throws {
        let fixture = try PipelineFixture(streaming: true)
        defer { _ = try? fixture.channel.finish() }
        let gate = fixture.loop.makePromise(of: Void.self)
        fixture.state.gate = gate.futureResult
        var gateCompleted = false
        defer {
            if !gateCompleted {
                gate.succeed(())
                fixture.loop.run()
            }
        }

        try fixture.write(
            "POST /upload HTTP/1.1\r\nHost: x\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n1\r\na\r\n"
        )
        try fixture.write("1\r\nb\r\n0\r\n\r\n")
        XCTAssertEqual(fixture.state.chunks, ["a"])
        XCTAssertEqual(fixture.state.finishes, 0)
        XCTAssertEqual(try fixture.read(), "")
        fixture.state.gate = nil
        gateCompleted = true
        gate.succeed(())
        fixture.loop.run()
        XCTAssertEqual(fixture.state.chunks, ["a", "b"])
        XCTAssertEqual(fixture.state.finishes, 1)
        XCTAssertTrue(try fixture.read().hasSuffix("uploaded"))
    }

    func testStreamingFallbackEnforcesIncrementalLimit() throws {
        let fixture = try PipelineFixture(streaming: true, maxBodyBytes: 3)
        defer { _ = try? fixture.channel.finish() }
        try fixture.write(
            "POST /upload HTTP/1.1\r\nHost: x\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n2\r\nab\r\n"
        )
        try fixture.write("2\r\ncd\r\n0\r\n\r\n")
        XCTAssertEqual(fixture.state.chunks, ["ab"])
        XCTAssertEqual(fixture.state.finishes, 0)
        XCTAssertEqual(fixture.state.errors, 1)
        XCTAssertTrue(try fixture.read().contains("413 Payload Too Large"))
    }

    func testStreamingFallbackPreservesMiddlewareShortCircuit() throws {
        let fixture = try PipelineFixture(streaming: true, middleware: true)
        defer { _ = try? fixture.channel.finish() }
        try fixture.assertStock()
        try fixture.write(
            "POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nab"
        )
        XCTAssertTrue(try fixture.read().hasSuffix("blocked"))
        XCTAssertEqual(fixture.state.begins, 0)
        XCTAssertEqual(fixture.state.chunks, [])
    }

    func testAmbiguousFramingRejectedOnSelectedTransports() throws {
        for streaming in [false, true] {
            let fixture = try PipelineFixture(streaming: streaming)
            defer { _ = try? fixture.channel.finish() }
            try fixture.write(
                "POST /upload HTTP/1.1\r\nHost: x\r\n"
                    + "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
            XCTAssertTrue(try fixture.read().contains("400 Bad Request"))
            XCTAssertEqual(fixture.state.begins, 0)
            XCTAssertEqual(fixture.state.ordinaryCalls, 0)
            XCTAssertFalse(fixture.channel.isActive)
        }
    }

    func testRefusedUpgradeDowngradesIntoNormalDispatch() throws {
        let fixture = try UpgradeRefusalFixture(
            installFilter: true
        )
        defer { _ = try? fixture.channel.finish() }

        try fixture.writeRefusedUpgradeRequest()
        fixture.loop.run()
        fixture.loop.run()

        // The upgrader never performs the upgrade: its build
        // step fails with the sentinel and the downgrade
        // continues.
        XCTAssertFalse(fixture.state.upgraded)
        XCTAssertTrue(fixture.state.attempted)

        // The re-delivered request reaches normal dispatch, which
        // answers with a real HTTP status carrying connection
        // close semantics. NIO's HTTP/1 decoder permanently stops
        // parsing after an upgrade-flagged request, so the
        // connection serves exactly this one request and then
        // closes instead of stranding the client on a pipeline
        // that can never parse again.
        let response = try fixture.readResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(response.contains("connection: close\r\n"))
        XCTAssertTrue(response.hasSuffix("\r\n\r\nNot Found"))
        XCTAssertFalse(
            fixture.channel.isActive
        )
    }

    func testRefusedUpgradeClosesWithoutFilterBaseline() throws {
        let fixture = try UpgradeRefusalFixture(
            installFilter: false
        )
        defer { _ = try? fixture.channel.finish() }

        try fixture.writeRefusedUpgradeRequest()
        fixture.loop.run()
        fixture.loop.run()

        // Without the filter the pre-existing behavior holds: the
        // refusal error surfaces to the runtime handler and tears
        // the connection down, giving up the connection for
        // keep-alive reuse. During that teardown race a status
        // response may or may not still reach the encoder, so the
        // deterministic differential here is the connection state.
        XCTAssertFalse(fixture.state.upgraded)
        XCTAssertTrue(fixture.state.attempted)
        XCTAssertFalse(fixture.channel.isActive)
    }

    func testUnknownUpgradeProtocolRespondsThenCloses() throws {
        let fixture = try UpgradeRefusalFixture(installFilter: true)
        defer { _ = try? fixture.channel.finish() }

        try fixture.writeRefusedUpgradeRequest(protocolName: "unknown")
        fixture.loop.run()

        // No upgrader was selected, so NIO emits no refusal error.
        // Its HTTP decoder nevertheless stops after an upgrade request.
        XCTAssertFalse(fixture.state.attempted)
        let response = try fixture.readResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(response.contains("connection: close\r\n"))
        XCTAssertTrue(response.hasSuffix("\r\n\r\nNot Found"))
        XCTAssertFalse(fixture.channel.isActive)
    }

    func testDeferredUpgradeRefusalReplaysCompleteRequestThenCloses() throws {
        let fixture = try UpgradeRefusalFixture(
            installFilter: true,
            deferredRefusal: true
        )
        defer { _ = try? fixture.channel.finish() }

        try fixture.writeRefusedUpgradeRequest()
        fixture.loop.run()
        XCTAssertTrue(fixture.state.attempted)
        XCTAssertTrue(fixture.channel.isActive)
        XCTAssertEqual(try fixture.readResponse(), "")

        // NIO has already consumed the original .end. On refusal it
        // replays a head plus synthetic .end to ordinary dispatch.
        let refusal = try XCTUnwrap(fixture.state.refusal)
        fixture.state.refusal = nil
        refusal.fail(UpgradeRefusalSentinelError())
        fixture.loop.run()

        let response = try fixture.readResponse()
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        XCTAssertTrue(response.contains("connection: close\r\n"))
        XCTAssertTrue(response.hasSuffix("\r\n\r\nNot Found"))
        XCTAssertFalse(fixture.state.upgraded)
        XCTAssertFalse(fixture.channel.isActive)
    }

    func testUnknownUpgradeWithMixedConnectionTokensCloses() throws {
        let fixture = try UpgradeRefusalFixture(installFilter: true)
        defer { _ = try? fixture.channel.finish() }

        try fixture.writeRefusedUpgradeRequest(
            protocolName: "unknown",
            connection: "keep-alive, UpGrAdE"
        )
        fixture.loop.run()

        let response = try fixture.readResponse()
        XCTAssertTrue(response.contains("connection: close\r\n"))
        XCTAssertFalse(fixture.channel.isActive)
    }

    func testUpgradeHeaderWithoutConnectionTokenKeepsServing() throws {
        let fixture = try UpgradeRefusalFixture(installFilter: true)
        defer { _ = try? fixture.channel.finish() }

        try fixture.writeRefusedUpgradeRequest(
            protocolName: "unknown",
            connection: "keep-alive"
        )
        fixture.loop.run()
        let first = try fixture.readResponse()
        XCTAssertTrue(first.hasSuffix("Not Found"))
        XCTAssertFalse(first.contains("connection: close"))
        XCTAssertTrue(fixture.channel.isActive)

        try fixture.channel.writeInbound(
            ByteBuffer(string: "GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
        )
        fixture.loop.run()
        XCTAssertTrue(try fixture.readResponse().hasSuffix("Not Found"))
        XCTAssertTrue(fixture.channel.isActive)
    }

    func testUpgradeErrorFilterDoesNotSwallowMidRequestError() throws {
        let fixture = try UpgradeRefusalFixture(
            installFilter: true
        )
        defer { _ = try? fixture.channel.finish() }

        // An incomplete request with the head already delivered to
        // the runtime handler: an error is not at a clean message
        // boundary here and must not be swallowed even though the
        // filter would otherwise match it.
        try fixture.channel.writeInbound(
            ByteBuffer(
                string:
                    "POST /upload HTTP/1.1\r\n"
                    + "Host: x\r\n"
                    + "Content-Length: 4\r\n"
                    + "\r\n"
                    + "ab"
            )
        )
        fixture.loop.run()
        fixture.channel.pipeline.fireErrorCaught(
            UpgradeRefusalSentinelError()
        )
        fixture.loop.run()

        XCTAssertFalse(
            fixture.channel.isActive
        )
    }
}

private final class UpgradeTestState:
    @unchecked Sendable
{
    var upgraded = false
    var completionSawRuntimeHandler =
        false
}

private final class UpgradeTestUpgrader:
    HTTPServerProtocolUpgrader,
    @unchecked Sendable
{
    let supportedProtocol = "test"
    let requiredUpgradeHeaders:
        [String] = []

    private let state:
        UpgradeTestState

    init(state: UpgradeTestState) {
        self.state = state
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest:
            HTTPRequestHead,
        initialResponseHeaders:
            HTTPHeaders
    ) -> EventLoopFuture<
        HTTPHeaders
    > {
        channel.eventLoop
            .makeSucceededFuture(
                initialResponseHeaders
            )
    }

    func upgrade(
        context:
            ChannelHandlerContext,
        upgradeRequest:
            HTTPRequestHead
    ) -> EventLoopFuture<Void> {
        state.upgraded = true

        return context.eventLoop
            .makeSucceededVoidFuture()
    }
}

/// Sentinel simulating the refusal error shape of an upgrade
/// capability: failing the upgrade build step makes the NIOHTTP1
/// upgrade machinery downgrade the request.
private struct UpgradeRefusalSentinelError:
    Error,
    Equatable
{
}

// All state and callbacks are confined to the fixture's EmbeddedEventLoop.
private final class UpgradeRefusalState:
    @unchecked Sendable
{
    var upgraded = false
    var attempted = false
    var refusal: EventLoopPromise<HTTPHeaders>?
}

/// Mirrors ``UpgradeTestUpgrader`` but always refuses its upgrade
/// by failing the build step, which is exactly how NIOWebSocket's
/// upgrader surfaces a rejected handshake.
private final class RefusingUpgradeTestUpgrader:
    HTTPServerProtocolUpgrader,
    @unchecked Sendable
{
    let supportedProtocol = "test"
    let requiredUpgradeHeaders:
        [String] = []

    private let state:
        UpgradeRefusalState
    private let deferredRefusal: Bool

    init(state: UpgradeRefusalState, deferredRefusal: Bool) {
        self.state = state
        self.deferredRefusal = deferredRefusal
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest:
            HTTPRequestHead,
        initialResponseHeaders:
            HTTPHeaders
    ) -> EventLoopFuture<
        HTTPHeaders
    > {
        state.attempted = true

        if deferredRefusal {
            let promise = channel.eventLoop.makePromise(of: HTTPHeaders.self)
            state.refusal = promise
            return promise.futureResult
        }

        return channel.eventLoop
            .makeFailedFuture(
                UpgradeRefusalSentinelError()
            )
    }

    func upgrade(
        context:
            ChannelHandlerContext,
        upgradeRequest:
            HTTPRequestHead
    ) -> EventLoopFuture<Void> {
        state.upgraded = true

        return context.eventLoop
            .makeSucceededVoidFuture()
    }
}

/// End-to-end fixture for the upgrade refusal path: it installs the
/// same stock HTTP pipeline that accepted production connections
/// use, with an upgrade configuration whose only upgrader refuses.
private final class UpgradeRefusalFixture {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let state = UpgradeRefusalState()

    init(
        installFilter: Bool,
        deferredRefusal: Bool = false
    ) throws {
        channel = EmbeddedChannel(loop: loop)
        let empty =
            RuntimePreparedResponse(
                status: .ok,
                headers:
                    HTTPHeaders(),
                bodyBuffer: nil
            )
        var notFoundHeaders =
            HTTPHeaders()
        let notFoundBody =
            ByteBuffer(string: "Not Found")
        notFoundHeaders.add(
            name: "content-length",
            value: String(
                notFoundBody.readableBytes
            )
        )
        let notFound =
            RuntimePreparedResponse(
                status: .notFound,
                headers:
                    notFoundHeaders,
                bodyBuffer:
                    notFoundBody
            )
        let dispatcher =
            RuntimeDispatcher(
                hasMiddleware: false,
                hasStreamingRoutes: false,
                hasStreamingRoute: {
                    _ in false
                },
                lookup: { _ in
                    .prepared(notFound)
                },
                dispatchPipeline: {
                    _, _ in
                    .response(empty.response)
                },
                mapError: {
                    _, _, _ in
                    .response(empty.response)
                },
                notFound: notFound,
                payloadTooLarge: empty,
                expectationFailed: empty,
                internalServerError: empty
            )
        let state = state
        let upgrader =
            RefusingUpgradeTestUpgrader(
                state: state,
                deferredRefusal: deferredRefusal
            )
        let refusalFilter:
            RuntimeUpgradeErrorFilter?

        if installFilter {
            refusalFilter = { error in
                error is UpgradeRefusalSentinelError
            }
        } else {
            refusalFilter = nil
        }
        let upgrade:
            NIOHTTPServerUpgradeSendableConfiguration =
                (
                    upgraders: [
                        upgrader,
                    ],
                    completionHandler: {
                        _ in
                    }
                )
        let configured =
            RuntimeServer
                .configureHTTPPipeline(
                    channel: channel,
                    dispatcher:
                        dispatcher,
                    configuration:
                        RuntimeServerConfiguration(
                            useTier1HTTP1:
                                true,
                            httpServerUpgrade:
                                upgrade,
                            upgradeErrorFilter:
                                refusalFilter
                        )
                )

        loop.run()
        try configured.wait()
        try channel.connect(
            to:
                SocketAddress(
                    ipAddress:
                        "127.0.0.1",
                    port: 1
                )
        )
        .wait()
    }

    func writeRefusedUpgradeRequest(
        protocolName: String = "test",
        connection: String = "upgrade"
    ) throws {
        try channel.writeInbound(
            ByteBuffer(
                string:
                    "GET /upgrade HTTP/1.1\r\n"
                    + "Host: x\r\n"
                    + "Connection: \(connection)\r\n"
                    + "Upgrade: \(protocolName)\r\n"
                    + "\r\n"
            )
        )
    }

    /// The installed encoder queues wire bytes, not typed response parts.
    func readResponse() throws -> String {
        var response = ""
        while let data = try channel.readOutbound(as: IOData.self) {
            guard case .byteBuffer(let buffer) = data else {
                XCTFail("Unexpected file region in the fixed response")
                continue
            }
            response += buffer.getString(
                at: buffer.readerIndex,
                length: buffer.readableBytes
            ) ?? ""
        }
        return response
    }
}

// All state and callbacks are confined to the fixture's EmbeddedEventLoop.
private final class PipelineState: @unchecked Sendable {
    var ordinaryCalls = 0
    var begins = 0
    var chunks: [String] = []
    var finishes = 0
    var errors = 0
    var gate: EventLoopFuture<Void>?
}

private final class PipelineFixture {
    let loop = EmbeddedEventLoop()
    let channel: EmbeddedChannel
    let state = PipelineState()

    init(
        useTier1: Bool = true,
        streaming: Bool = false,
        middleware: Bool = false,
        maxBodyBytes: Int = 1024,
        streamingResponse: Bool = false,
        canonicalResponse: Bool = false,
        preparedResponse: Bool = false
    ) throws {
        channel = EmbeddedChannel(loop: loop)
        let state = state
        let canonicalHeaders = HTTPHeaders([
            ("content-type", "text/plain; charset=utf-8"),
            ("content-length", "2"),
        ])
        let canonicalReply = RuntimeResponse(
            status: .ok,
            headers: canonicalHeaders,
            body: .text("ok"),
            contentLengthIsNormalized: true,
            canonicalHead: HTTPResponseHead(version: .http1_1, status: .ok, headers: canonicalHeaders),
            canonicalBodyLength: 2
        )
        let preparedReply = RuntimePreparedResponse(
            status: .ok,
            headers: canonicalHeaders,
            bodyBuffer: ByteBuffer(string: "ok")
        )
        let stream = RuntimeStreamingAction(
            begin: { _, eventLoop in
                let registration = RuntimeStreamRegistration(eventLoop: eventLoop)
                // The framework's streaming-start closure owns middleware
                // dispatch and bypass registration for a short circuit.
                if middleware {
                    registration.bypassIfPending()
                    return RuntimeStreamingStart(
                        result: .response(Self.text("blocked")),
                        registration: registration,
                        maxBodyBytes: maxBodyBytes,
                        declaredBodyTooLarge: false
                    )
                }
                state.begins += 1
                let session = RuntimeStreamSession(
                    consumer: RuntimeStreamConsumer(
                        onChunk: { buffer in
                            state.chunks.append(String(decoding: buffer.readableBytesView, as: UTF8.self))
                            return state.gate
                        },
                        onFinish: {
                            state.finishes += 1
                            return eventLoop.makeSucceededFuture(Self.text("uploaded"))
                        },
                        onError: { _ in state.errors += 1 }
                    ),
                    eventLoop: eventLoop
                )
                registration.register(session)
                return RuntimeStreamingStart(
                    result: .future(session.responseFuture),
                    registration: registration,
                    maxBodyBytes: maxBodyBytes,
                    declaredBodyTooLarge: false
                )
            },
            runAggregated: { _, _ in .response(Self.text("aggregated")) }
        )
        let dispatcher = RuntimeDispatcher(
            hasMiddleware: middleware,
            hasStreamingRoutes: streaming,
            hasStreamingRoute: { streaming && $0 == .POST },
            lookup: { head in
                if preparedResponse {
                    return .prepared(preparedReply)
                }
                if streaming, head.method == .POST, head.uri == "/upload" {
                    return .streaming(stream)
                }
                return .sync(
                    RuntimeSyncAction { _ in
                        state.ordinaryCalls += 1
                        if streamingResponse {
                            return RuntimeResponse(
                                status: .ok,
                                headers: HTTPHeaders(),
                                body: .stream(
                                    RuntimeResponseStream(produce: { writer in
                                        writer.writeString("ok")
                                        return writer.eventLoop.makeSucceededVoidFuture()
                                    })
                                )
                            )
                        }
                        if canonicalResponse {
                            return canonicalReply
                        }
                        return Self.text("ok")
                    }
                )
            },
            dispatchPipeline: { _, _ in .response(Self.text("blocked")) },
            mapError: { _, _, _ in .response(Self.text("error")) },
            notFound: Self.fixed(.notFound),
            payloadTooLarge: Self.fixed(.payloadTooLarge),
            expectationFailed: Self.fixed(.expectationFailed),
            internalServerError: Self.fixed(.internalServerError)
        )
        let configured = RuntimeServer.configureHTTPPipeline(
            channel: channel,
            dispatcher: dispatcher,
            configuration: RuntimeServerConfiguration(
                maxRequestBodyBytes: maxBodyBytes,
                useTier1HTTP1: useTier1
            )
        )
        loop.run()
        try configured.wait()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
    }

    func assertStock(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNoThrow(
            try channel.pipeline.syncOperations
                .handler(type: RuntimeConnectionHandler.self),
            file: file,
            line: line
        )
        XCTAssertThrowsError(
            try channel.pipeline.syncOperations
                .handler(type: WTHTTP1ConnectionHandler.self),
            file: file,
            line: line
        )
    }

    func write(_ text: String) throws {
        try channel.writeInbound(ByteBuffer(string: text))
        loop.run()
    }

    func read() throws -> String {
        var result = ""
        while let data = try channel.readOutbound(as: IOData.self) {
            switch data {
            case .byteBuffer(let buffer):
                result += String(decoding: buffer.readableBytesView, as: UTF8.self)
            case .fileRegion:
                XCTFail("Unexpected file region")
            }
        }
        return result
    }

    static func text(_ text: String) -> RuntimeResponse {
        RuntimeResponse(status: .ok, headers: HTTPHeaders(), body: .text(text))
    }

    static func fixed(_ status: HTTPResponseStatus) -> RuntimePreparedResponse {
        RuntimePreparedResponse(
            status: status,
            headers: HTTPHeaders([("content-length", "0")]),
            bodyBuffer: nil
        )
    }
}
