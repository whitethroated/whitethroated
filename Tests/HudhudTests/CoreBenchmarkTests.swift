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

        let paddedName = benchmarkCase.name.padding(
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
            }

        case .future:
            checksum &+= 1
        }
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
