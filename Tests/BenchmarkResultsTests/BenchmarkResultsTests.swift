import XCTest
@testable import BenchmarkResults

final class BenchmarkResultsTests: XCTestCase {
    private func sample(
        runID: String = "round-1", path: String = "/", start: UInt64 = 1_000,
        end: UInt64 = 101_000, latencies: [UInt64] = [1_000, 2_000],
        latency: Bool = true, completed: Int = 3
    ) -> BenchmarkSample {
        BenchmarkSample(
            runID: runID, clientHost: "client", method: "GET", path: path,
            targetHost: "127.0.0.1", port: 3000, connections: 1, threads: 1,
            tcpNoDelay: true, collectLatency: latency, requested: 3,
            completed: completed, bodyBytes: 0, startNanoseconds: start,
            endNanoseconds: end, latencyNanoseconds: latencies
        )
    }

    func testPoolsSamplesRatherThanAveragingPercentiles() throws {
        let result = try BenchmarkSummary(samples: [
            sample(), sample(start: 11_000, end: 111_000, latencies: [30_000, 40_000])
        ])
        XCTAssertEqual(result.latencySamples, 4)
        XCTAssertEqual(result.p50Microseconds, 2)
        XCTAssertEqual(result.p99Microseconds, 30)
        XCTAssertEqual(result.averageMicroseconds, 18.25)
        XCTAssertEqual(result.maximumMicroseconds, 40)
        XCTAssertEqual(result.connections, 2)
        // Entire measurement window, not sum of shard-local RPS.
        XCTAssertEqual(result.requestsPerSecond, 6 / 0.00011, accuracy: 0.000001)
    }

    func testThroughputOnlyAndSingleRequestConnections() throws {
        let throughput = try BenchmarkSummary(samples: [sample(latencies: [], latency: false)])
        XCTAssertNil(throughput.p99Microseconds)
        let one = BenchmarkSample(
            runID: "one", clientHost: "client", method: "GET", path: "/",
            targetHost: "localhost", port: 3000, connections: 1, threads: 1,
            tcpNoDelay: true, collectLatency: true, requested: 1, completed: 1,
            bodyBytes: 0, startNanoseconds: 1, endNanoseconds: 2,
            latencyNanoseconds: []
        )
        XCTAssertEqual(try BenchmarkSummary(samples: [one]).latencySamples, 0)
    }

    func testRejectsIncompleteOrIncompatibleRounds() {
        let duplicate = sample()
        XCTAssertThrowsError(try BenchmarkSummary(samples: [duplicate, duplicate]))
        XCTAssertThrowsError(try BenchmarkSummary(samples: []))
        XCTAssertThrowsError(try BenchmarkSummary(samples: [sample(completed: 2)]))
        XCTAssertThrowsError(try BenchmarkSummary(samples: [sample(latencies: [1])]))
        XCTAssertThrowsError(try BenchmarkSummary(samples: [sample(), sample(runID: "round-2")]))
        XCTAssertThrowsError(try BenchmarkSummary(samples: [sample(), sample(path: "/json")]))
        XCTAssertThrowsError(try BenchmarkSummary(samples: [sample(), sample(start: 102_000, end: 202_000)]))
        XCTAssertThrowsError(try BenchmarkSummary(samples: [sample(end: 1_000)]))
        XCTAssertThrowsError(try BenchmarkSummary(samples: [sample(latencies: [1, 200_000])]))
    }

    func testRoundTripPreservesNanosecondSamples() throws {
        let original = sample()
        let decoded = try JSONDecoder().decode(BenchmarkSample.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.latencyNanoseconds, original.latencyNanoseconds)
        XCTAssertEqual(try BenchmarkSummary(samples: [decoded]).p99Microseconds, 1)
    }
}
