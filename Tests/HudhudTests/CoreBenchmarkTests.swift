import Dispatch
import Foundation
import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class CoreBenchmarkTests: XCTestCase {
    func testCoreDispatchBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment

        try XCTSkipUnless(
            environment["HUDHUD_CORE_BENCHMARK"] == "1",
            "Set HUDHUD_CORE_BENCHMARK=1 to run core benchmarks."
        )

        let iterations = Int(
            environment["HUDHUD_CORE_ITERATIONS"] ?? "1000000"
        ) ?? 1_000_000

        precondition(iterations > 0)

        let app = Application()
        let loop = EmbeddedEventLoop()
        let emptyBody = ByteBufferAllocator().buffer(
            capacity: 0
        )

        app.get(
            "/prepared",
            response: .text("Hello, World!")
        )

        app.get("/plaintext") { _ in
            .text("Hello, World!")
        }

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        app.get("/query") { request in
            .text(request.query("q") ?? "")
        }

        app.get("/method") { request in
            .text(
                request.method == .get
                    ? "GET"
                    : "OTHER"
            )
        }

        let cases = [
            BenchmarkCase(
                name: "prepared-static",
                head: makeHead("/prepared")
            ),
            BenchmarkCase(
                name: "sync-static",
                head: makeHead("/plaintext")
            ),
            BenchmarkCase(
                name: "sync-param",
                head: makeHead("/users/42")
            ),
            BenchmarkCase(
                name: "sync-query",
                head: makeHead("/query?q=hudhud")
            ),
            BenchmarkCase(
                name: "sync-method",
                head: makeHead("/method")
            )
        ]

        print("")
        print(
            "Hudhud core dispatch benchmark "
            + "iterations=\(iterations)"
        )

        for benchmarkCase in cases {
            benchmark(
                benchmarkCase,
                iterations: iterations,
                app: app,
                eventLoop: loop,
                body: emptyBody
            )
        }

        print("")
    }

    func testTransportWriterBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment

        try XCTSkipUnless(
            environment["HUDHUD_TRANSPORT_BENCHMARK"] == "1",
            "Set HUDHUD_TRANSPORT_BENCHMARK=1 to run transport benchmarks."
        )

        let iterations = Int(
            environment["HUDHUD_TRANSPORT_ITERATIONS"]
                ?? "100000"
        ) ?? 100_000

        precondition(iterations > 0)

        let preparedApp = Application()
        preparedApp.get(
            "/prepared",
            response: .text("Hello, World!")
        )

        let syncApp = Application()
        syncApp.get("/plaintext") { _ in
            .text("Hello, World!")
        }

        print("")
        print(
            "Hudhud transport writer benchmark "
            + "iterations=\(iterations)"
        )

        try benchmarkTransport(
            name: "prepared-writer",
            app: preparedApp,
            uri: "/prepared",
            iterations: iterations
        )

        try benchmarkTransport(
            name: "sync-writer",
            app: syncApp,
            uri: "/plaintext",
            iterations: iterations
        )

        print("")
    }

    private func benchmark(
        _ benchmarkCase: BenchmarkCase,
        iterations: Int,
        app: Application,
        eventLoop: EmbeddedEventLoop,
        body: ByteBuffer
    ) {
        var checksum = 0

        for _ in 0..<10_000 {
            consume(
                app.respondTransport(
                    head: benchmarkCase.head,
                    body: body,
                    on: eventLoop
                ),
                checksum: &checksum
            )
        }

        let start = DispatchTime.now().uptimeNanoseconds

        for _ in 0..<iterations {
            consume(
                app.respondTransport(
                    head: benchmarkCase.head,
                    body: body,
                    on: eventLoop
                ),
                checksum: &checksum
            )
        }

        let end = DispatchTime.now().uptimeNanoseconds
        let elapsed = end - start
        let nanosecondsPerOperation =
            Double(elapsed) / Double(iterations)
        let operationsPerSecond =
            1_000_000_000 / nanosecondsPerOperation

        printBenchmarkLine(
            name: benchmarkCase.name,
            nanosecondsPerOperation:
                nanosecondsPerOperation,
            operationsPerSecond:
                operationsPerSecond,
            checksum: checksum
        )
    }

    private func benchmarkTransport(
        name: String,
        app: Application,
        uri: String,
        iterations: Int
    ) throws {
        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )
        let head = makeHead(uri)
        var checksum = 0

        for _ in 0..<1_000 {
            try writeAndDrain(
                head: head,
                channel: channel,
                checksum: &checksum
            )
        }

        let start = DispatchTime.now().uptimeNanoseconds

        for _ in 0..<iterations {
            try writeAndDrain(
                head: head,
                channel: channel,
                checksum: &checksum
            )
        }

        let end = DispatchTime.now().uptimeNanoseconds
        let elapsed = end - start
        let nanosecondsPerOperation =
            Double(elapsed) / Double(iterations)
        let operationsPerSecond =
            1_000_000_000 / nanosecondsPerOperation

        printBenchmarkLine(
            name: name,
            nanosecondsPerOperation:
                nanosecondsPerOperation,
            operationsPerSecond:
                operationsPerSecond,
            checksum: checksum
        )

        _ = try channel.finish()
    }

    @inline(__always)
    private func writeAndDrain(
        head: HTTPRequestHead,
        channel: EmbeddedChannel,
        checksum: inout Int
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        for _ in 0..<3 {
            guard let part = try channel.readOutbound(
                as: HTTPServerResponsePart.self
            ) else {
                preconditionFailure(
                    "Expected three outbound response parts"
                )
            }

            switch part {
            case .head(let responseHead):
                checksum &+= Int(
                    responseHead.status.code
                )

            case .body:
                checksum &+= 1

            case .end:
                checksum &+= 1
            }
        }
    }

    @inline(never)
    private func consume(
        _ result: ResponderResult,
        checksum: inout Int
    ) {
        switch result {
        case .prepared(let prepared):
            checksum &+= Int(
                prepared.http11Head.status.code
            )

        case .immediate(let response):
            checksum &+= Int(response.status.code)

            switch response.body {
            case .empty:
                break
            case .text(let value):
                checksum &+= value.utf8.count
            case .bytes(let value):
                checksum &+= value.count
            case .buffer(let value):
                checksum &+= value.readableBytes
            case .fileRegion(let value):
                checksum &+= value.readableBytes
            case .stream:
                checksum &+= 1
            }

        case .streaming:
            checksum &+= 1

        case .future:
            checksum &+= 1
        }
    }

    private func printBenchmarkLine(
        name: String,
        nanosecondsPerOperation: Double,
        operationsPerSecond: Double,
        checksum: Int
    ) {
        let paddedName = name.padding(
            toLength: 20,
            withPad: " ",
            startingAt: 0
        )
        let nsText = String(
            format: "%.2f",
            nanosecondsPerOperation
        )
        let opsText = String(
            format: "%.0f",
            operationsPerSecond
        )

        print(
            "\(paddedName) "
            + "\(nsText) ns/op "
            + "\(opsText) ops/s "
            + "checksum=\(checksum)"
        )
    }

    private func makeHead(
        _ uri: String
    ) -> HTTPRequestHead {
        HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: uri
        )
    }
}

private struct BenchmarkCase {
    let name: String
    let head: HTTPRequestHead
}
