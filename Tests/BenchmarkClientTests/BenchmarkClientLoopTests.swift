import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

final class BenchmarkClientLoopTests: XCTestCase {
    func testConfiguredClientLoopsAllReceiveConnections() throws {
        // Real channels are required to exercise ClientBootstrap's group
        // selection; EmbeddedEventLoop does not model that round-robin step.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let channel = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: true,
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(LoopDistributionServerHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? channel.close().wait() }
        let port = try XCTUnwrap(channel.localAddress?.port)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/release/whitethroated-benchmark-client")

        // Odd counts protect the working fallback; even counts reproduce
        // the previous skip (2 -> 1, 4 -> 2, and 8 -> 4 channel loops).
        let cases = [(1, "0"), (2, "0"), (3, "0"), (4, "0"), (8, "0"), (4, "1"), (4, "default")]
        for (threads, noDelay) in cases {
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "WHITETHROATED_BENCH_OUTPUT")
            environment.removeValue(forKey: "WHITETHROATED_BENCH_RUN_ID")
            environment.merge([
                "WHITETHROATED_BENCH_HOST": "127.0.0.1",
                "WHITETHROATED_BENCH_PORT": String(port),
                "WHITETHROATED_BENCH_METHOD": "GET",
                "WHITETHROATED_BENCH_PATH": "/",
                "WHITETHROATED_BENCH_CONNECTIONS": "64",
                "WHITETHROATED_BENCH_REQUESTS": "512",
                "WHITETHROATED_BENCH_THREADS": String(threads),
                "WHITETHROATED_BENCH_LATENCY": "1",
                "WHITETHROATED_BENCH_CONN_STATS": "1",
                "WHITETHROATED_BENCH_TCP_NODELAY": noDelay,
            ]) { _, value in value }
            if noDelay == "default" {
                environment.removeValue(forKey: "WHITETHROATED_BENCH_TCP_NODELAY")
            }
            let pipe = Pipe()
            let process = Process()
            process.executableURL = executable
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(output.prefix(2000)))
            guard process.terminationStatus == 0 else { continue }
            XCTAssertTrue(output.contains("requests=512 "), output)
            XCTAssertTrue(output.contains("response_body_bytes=0\n"), output)
            XCTAssertTrue(output.contains("latency_samples=448\n"), output)
            XCTAssertTrue(output.contains("channel_event_loops=\(threads)\n"), output)
            XCTAssertTrue(output.contains("conn_used_loops=\(threads)\n"), output)
            XCTAssertTrue(output.contains("tcp_nodelay_observed=\(noDelay == "0" ? 0 : 1)\n"), output)
        }
    }
}

// Stateless: each callback only writes to the context supplied by NIO.
private final class LoopDistributionServerHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        context.write(
            wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: .http1_1,
                        status: .ok,
                        headers: HTTPHeaders([("content-length", "0")])
                    )
                )
            ),
            promise: nil
        )
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
