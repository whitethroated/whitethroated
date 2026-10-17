import Foundation

/// One successful client shard. Times use the load-generator host's monotonic
/// clock. Never merge different hosts or different measured rounds.
public struct BenchmarkSample: Codable, Sendable {
    public let schemaVersion: Int
    public let sampleID: UUID
    public let runID: String
    public let clientHost: String
    public let method: String
    public let path: String
    public let targetHost: String
    public let port: Int
    public let connections: Int
    public let threads: Int
    public let tcpNoDelay: Bool
    public let collectLatency: Bool
    public let requested: Int
    public let completed: Int
    public let bodyBytes: Int
    public let startNanoseconds: UInt64
    public let endNanoseconds: UInt64
    public let latencyNanoseconds: [UInt64]

    public init(
        runID: String, clientHost: String, method: String, path: String,
        targetHost: String, port: Int, connections: Int, threads: Int,
        tcpNoDelay: Bool, collectLatency: Bool, requested: Int, completed: Int,
        bodyBytes: Int, startNanoseconds: UInt64, endNanoseconds: UInt64,
        latencyNanoseconds: [UInt64]
    ) {
        schemaVersion = 1
        sampleID = UUID()
        self.runID = runID
        self.clientHost = clientHost
        self.method = method
        self.path = path
        self.targetHost = targetHost
        self.port = port
        self.connections = connections
        self.threads = threads
        self.tcpNoDelay = tcpNoDelay
        self.collectLatency = collectLatency
        self.requested = requested
        self.completed = completed
        self.bodyBytes = bodyBytes
        self.startNanoseconds = startNanoseconds
        self.endNanoseconds = endNanoseconds
        self.latencyNanoseconds = latencyNanoseconds
    }
}

public enum BenchmarkMergeError: Error {
    case emptyInput
    case incompatibleSamples
    case invalidSample
    case nonoverlappingShards
}

public struct BenchmarkSummary: Codable, Sendable {
    public let schemaVersion: Int
    public let runID: String
    public let method: String
    public let path: String
    public let clientHost: String
    public let collectLatency: Bool
    public let shards: Int
    public let connections: Int
    public let completed: Int
    public let bodyBytes: Int
    public let elapsedSeconds: Double
    public let requestsPerSecond: Double
    public let latencySamples: Int
    public let averageMicroseconds: Double?
    public let p50Microseconds: Double?
    public let p75Microseconds: Double?
    public let p90Microseconds: Double?
    public let p99Microseconds: Double?
    public let p99_999Microseconds: Double?
    public let maximumMicroseconds: Double?

    public init(samples: [BenchmarkSample]) throws {
        guard let first = samples.first else { throw BenchmarkMergeError.emptyInput }
        guard Set(samples.map(\.sampleID)).count == samples.count else {
            throw BenchmarkMergeError.invalidSample
        }
        for sample in samples {
            guard sample.schemaVersion == 1,
                  sample.runID == first.runID, !sample.runID.isEmpty,
                  sample.clientHost == first.clientHost,
                  sample.method == first.method, sample.path == first.path,
                  sample.targetHost == first.targetHost,
                  sample.threads == first.threads,
                  sample.tcpNoDelay == first.tcpNoDelay,
                  sample.collectLatency == first.collectLatency
            else { throw BenchmarkMergeError.incompatibleSamples }
            guard sample.connections > 0, sample.threads > 0,
                  sample.requested >= sample.connections,
                  sample.completed == sample.requested, sample.bodyBytes >= 0,
                  sample.endNanoseconds > sample.startNanoseconds,
                  sample.latencyNanoseconds.count == (sample.collectLatency
                    ? sample.completed - sample.connections : 0),
                  sample.latencyNanoseconds.allSatisfy({
                    $0 <= sample.endNanoseconds - sample.startNanoseconds
                  })
            else { throw BenchmarkMergeError.invalidSample }
        }
        let start = samples.map(\.startNanoseconds).min()!
        let end = samples.map(\.endNanoseconds).max()!
        guard samples.map(\.startNanoseconds).max()! < samples.map(\.endNanoseconds).min()!
        else { throw BenchmarkMergeError.nonoverlappingShards }
        let latencies = samples.flatMap(\.latencyNanoseconds).sorted()
        func percentile(_ fraction: Double) -> Double? {
            guard !latencies.isEmpty else { return nil }
            return Double(latencies[Int(Double(latencies.count - 1) * fraction)]) / 1_000
        }
        schemaVersion = 1
        runID = first.runID
        method = first.method
        path = first.path
        clientHost = first.clientHost
        collectLatency = first.collectLatency
        shards = samples.count
        connections = samples.reduce(0) { $0 + $1.connections }
        completed = samples.reduce(0) { $0 + $1.completed }
        bodyBytes = samples.reduce(0) { $0 + $1.bodyBytes }
        elapsedSeconds = Double(end - start) / 1_000_000_000
        requestsPerSecond = Double(completed) / elapsedSeconds
        latencySamples = latencies.count
        averageMicroseconds = latencies.isEmpty ? nil
            : latencies.reduce(0.0) { $0 + Double($1) } / Double(latencies.count) / 1_000
        p50Microseconds = percentile(0.5)
        p75Microseconds = percentile(0.75)
        p90Microseconds = percentile(0.9)
        p99Microseconds = percentile(0.99)
        p99_999Microseconds = percentile(0.99999)
        maximumMicroseconds = latencies.last.map { Double($0) / 1_000 }
    }
}
