import Testing

import NIOCore
import NIOEmbedded
import NIOHTTP1

@testable import WhiteThroatedHTTP1

/// Locks stock-pipeline wire behavior for upgrade attempts and decode
/// errors so the experimental handler can mirror it exactly.
private final class WTStockProbeCapture: ChannelInboundHandler,
    RemovableChannelHandler
{
    typealias InboundIn = HTTPServerRequestPart

    var parts: [String] = []
    var errors: [String] = []

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            parts.append("head \(head.method) \(head.uri)")

        case .body(var body):
            parts.append("body \(body.readableBytes)")

        case .end:
            parts.append("end")
        }
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        errors.append(String(describing: error))
        context.fireErrorCaught(error)
    }
}

private struct WTStockProbeResult {
    var inbound: [String]
    var errors: [String]
    var writeError: String?
    var outboundPrefix: String
    var outboundLength: Int
}

private func probeStockPipeline(
    _ request: String
) throws -> WTStockProbeResult {
    let channel = EmbeddedChannel()
    let capture = WTStockProbeCapture()
    try channel.pipeline.syncOperations
        .configureHTTPServerPipeline(
            withPipeliningAssistance: true,
            withErrorHandling: true
        )
    try channel.pipeline.syncOperations.addHandler(capture)

    var buffer = channel.allocator.buffer(
        capacity: request.utf8.count
    )
    buffer.writeString(request)

    var writeError: String?
    do {
        try channel.writeInbound(buffer)
    } catch {
        writeError = String(describing: error)
    }

    var outbound = ""
    while let chunk = try channel.readOutbound(
        as: ByteBuffer.self
    ) {
        var copy = chunk
        outbound += copy.readString(
            length: copy.readableBytes
        ) ?? ""
    }

    return WTStockProbeResult(
        inbound: capture.parts,
        errors: capture.errors,
        writeError: writeError,
        outboundPrefix: String(outbound.prefix(80)),
        outboundLength: outbound.count
    )
}

@Suite struct WTHTTP1StockBehaviorTests {
    @Test func stockUpgradeWithoutUpgraders() throws {
        // Observed stock behavior: without configured upgraders the
        // pipeline routes upgrade attempts as normal requests (no
        // error, no automatic response). Tier 1 mirrors this.
        let result = try probeStockPipeline(
            "GET /ws HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: x\r\n\r\n"
        )

        #expect(result.inbound == ["head GET /ws", "end"])
        #expect(result.errors == [])
        #expect(result.writeError == nil)
        #expect(result.outboundLength == 0)
    }

    @Test func stockDecodeErrorYields400() throws {
        let result = try probeStockPipeline(
            "GET / HTTP/9.9\r\n\r\n"
        )

        #expect(
            result.outboundPrefix.hasPrefix("HTTP/1.1 400"),
            "inbound=\(result.inbound) errors=\(result.errors) writeError=\(result.writeError as Any) outbound=\(result.outboundPrefix.debugDescription)"
        )
    }
}
