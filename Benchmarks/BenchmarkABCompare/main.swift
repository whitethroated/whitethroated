import BenchmarkResults
import Foundation

private enum ComparisonFailure:
    Error,
    CustomStringConvertible
{
    case invalidArguments
    case incompatibleCampaigns(String)
    case invalidSummary(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "Expected baseline and candidate campaign directories"

        case .incompatibleCampaigns(let message):
            return message

        case .invalidSummary(let message):
            return message
        }
    }
}

private enum RouteRole:
    String,
    Codable
{
    case control
    case candidate
}

private struct RouteContract {
    let path: String
    let label: String
    let role: RouteRole
}

private struct MetricSet:
    Codable
{
    let requestsPerSecond:
        PairedBenchmarkMetricComparison
    let p50Microseconds:
        PairedBenchmarkMetricComparison
    let p90Microseconds:
        PairedBenchmarkMetricComparison
    let p99Microseconds:
        PairedBenchmarkMetricComparison
    let p99_999Microseconds:
        PairedBenchmarkMetricComparison
    let maximumMicroseconds:
        PairedBenchmarkMetricComparison
    let requestsPerCPUSecond:
        PairedBenchmarkMetricComparison
    let sampledPeakAggregateRSSKiB:
        PairedBenchmarkMetricComparison
}

private struct CellReport:
    Codable
{
    let path: String
    let role: RouteRole
    let concurrency: Int
    let metrics: MetricSet
}

private struct ComparisonReport:
    Codable
{
    let schemaVersion: Int
    let baselineHead: String
    let candidateHead: String
    let serverProduct: String
    let host: String
    let swiftVersion: String
    let rounds: Int
    let cells: [CellReport]
}

private struct CampaignInput {
    let directory: URL
    let configuration: CampaignConfiguration
    let head: String
    let host: String
    let swiftVersion: String
    let packageResolved: String
    let worktreeDiff: String

    init(path: String) throws {
        directory = URL(
            fileURLWithPath: path,
            isDirectory: true
        ).standardizedFileURL

        configuration = try Self.decode(
            CampaignConfiguration.self,
            from: directory
                .appendingPathComponent(
                    "configuration.json"
                )
        )

        head = try Self.readText(
            "head.txt",
            in: directory
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        host = try Self.readText(
            "host.txt",
            in: directory
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        swiftVersion = try Self.readText(
            "swift-version.txt",
            in: directory
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        packageResolved = try Self.readText(
            "Package.resolved.txt",
            in: directory
        )
        worktreeDiff = try Self.readText(
            "worktree.diff",
            in: directory
        )

        guard
            !head.isEmpty,
            !host.isEmpty,
            !swiftVersion.isEmpty
        else {
            throw ComparisonFailure.invalidSummary(
                "Campaign identity metadata is incomplete"
            )
        }
    }

    func summary(
        round: Int,
        route: RouteContract,
        concurrency: Int,
        mode: String
    ) throws -> BenchmarkSummary {
        let name =
            "r\(round)-1x2-"
            + route.label
            + "-c\(concurrency)-"
            + mode
            + "-pooled.json"

        let summary = try Self.decode(
            BenchmarkSummary.self,
            from: directory
                .appendingPathComponent(name)
        )

        let expectedRunID =
            "r\(round)-1x2-"
            + route.label
            + "-c\(concurrency)-"
            + mode

        guard
            summary.schemaVersion == 1,
            summary.runID == expectedRunID,
            summary.method == "GET",
            summary.path == route.path,
            summary.connections == concurrency,
            summary.shards
                == configuration.shards,
            summary.completed
                == configuration.requestsPerShard
                    * configuration.shards,
            summary.bodyBytes
                == summary.completed * 13
        else {
            throw ComparisonFailure.invalidSummary(
                "Unexpected benchmark summary contract in \(name)"
            )
        }

        return summary
    }

    func resources(
        round: Int,
        route: RouteContract,
        concurrency: Int
    ) throws -> ResourceSummary {
        let name =
            "r\(round)-1x2-"
            + route.label
            + "-c\(concurrency)-resource-resources.json"

        return try Self.decode(
            ResourceSummary.self,
            from: directory
                .appendingPathComponent(name)
        )
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T {
        try JSONDecoder().decode(
            T.self,
            from: Data(contentsOf: url)
        )
    }

    private static func readText(
        _ name: String,
        in directory: URL
    ) throws -> String {
        try String(
            contentsOf:
                directory.appendingPathComponent(
                    name
                ),
            encoding: .utf8
        )
    }
}

private let routes: [RouteContract] = [
    RouteContract(
        path: "/response-stream-known",
        label: "stream-known",
        role: .control
    ),
    RouteContract(
        path: "/response-stream",
        label: "stream-chunked",
        role: .control
    ),
    RouteContract(
        path: "/response-stream-ab-known",
        label: "stream-ab-known",
        role: .candidate
    ),
    RouteContract(
        path: "/response-stream-ab",
        label: "stream-ab-chunked",
        role: .candidate
    ),
    RouteContract(
        path: "/response-stream-flush",
        label: "stream-flush",
        role: .control
    ),
]

private func requireComparable(
    _ baseline: CampaignInput,
    _ candidate: CampaignInput
) throws {
    let left = baseline.configuration
    let right = candidate.configuration

    guard
        left.profile == .responseStream,
        right.profile == .responseStream
    else {
        throw ComparisonFailure.incompatibleCampaigns(
            "Both campaigns must use profile response-stream"
        )
    }

    guard
        !left.smoke,
        !right.smoke
    else {
        throw ComparisonFailure.incompatibleCampaigns(
            "Smoke campaigns are correctness evidence only"
        )
    }

    guard
        baseline.host == candidate.host,
        baseline.swiftVersion
            == candidate.swiftVersion,
        baseline.packageResolved
            == candidate.packageResolved
    else {
        throw ComparisonFailure.incompatibleCampaigns(
            "Host, Swift toolchain, or Package.resolved differs"
        )
    }

    guard
        baseline.worktreeDiff.isEmpty,
        candidate.worktreeDiff.isEmpty
    else {
        throw ComparisonFailure.incompatibleCampaigns(
            "Campaign worktrees must be clean"
        )
    }

    guard
        left.serverProduct
            == right.serverProduct,
        left.rounds == right.rounds,
        left.concurrencies
            == right.concurrencies,
        left.requestsPerShard
            == right.requestsPerShard,
        left.warmupRequests
            == right.warmupRequests,
        left.shards == right.shards,
        left.serverLoops
            == right.serverLoops
    else {
        throw ComparisonFailure.incompatibleCampaigns(
            "Campaign configurations are not comparable"
        )
    }
}

private func required(
    _ value: Double?,
    name: String
) throws -> Double {
    guard let value, value.isFinite else {
        throw ComparisonFailure.invalidSummary(
            "Missing or non-finite latency metric: \(name)"
        )
    }

    return value
}

private func compare(
    baseline: CampaignInput,
    candidate: CampaignInput
) throws -> ComparisonReport {
    try requireComparable(
        baseline,
        candidate
    )

    var cells: [CellReport] = []

    for route in routes {
        for concurrency in
            baseline.configuration
                .concurrencies
        {
            var baselineRPS: [Double] = []
            var candidateRPS: [Double] = []
            var baselineP50: [Double] = []
            var candidateP50: [Double] = []
            var baselineP90: [Double] = []
            var candidateP90: [Double] = []
            var baselineP99: [Double] = []
            var candidateP99: [Double] = []
            var baselineP99_999: [Double] = []
            var candidateP99_999: [Double] = []
            var baselineMax: [Double] = []
            var candidateMax: [Double] = []
            var baselineCPU: [Double] = []
            var candidateCPU: [Double] = []
            var baselineRSS: [Double] = []
            var candidateRSS: [Double] = []

            for round in
                1...baseline.configuration.rounds
            {
                let baseThroughput =
                    try baseline.summary(
                        round: round,
                        route: route,
                        concurrency: concurrency,
                        mode: "throughput"
                    )
                let candidateThroughput =
                    try candidate.summary(
                        round: round,
                        route: route,
                        concurrency: concurrency,
                        mode: "throughput"
                    )

                guard
                    !baseThroughput
                        .collectLatency,
                    !candidateThroughput
                        .collectLatency,
                    baseThroughput.clientHost
                        == candidateThroughput.clientHost
                else {
                    throw ComparisonFailure
                        .invalidSummary(
                            "Throughput cell unexpectedly collected latency"
                        )
                }

                baselineRPS.append(
                    baseThroughput.requestsPerSecond
                )
                candidateRPS.append(
                    candidateThroughput
                        .requestsPerSecond
                )

                let baseLatency =
                    try baseline.summary(
                        round: round,
                        route: route,
                        concurrency: concurrency,
                        mode: "latency"
                    )
                let candidateLatency =
                    try candidate.summary(
                        round: round,
                        route: route,
                        concurrency: concurrency,
                        mode: "latency"
                    )

                guard
                    baseLatency.collectLatency,
                    candidateLatency.collectLatency,
                    baseLatency.clientHost
                        == candidateLatency.clientHost
                else {
                    throw ComparisonFailure
                        .invalidSummary(
                            "Latency cell did not collect latency"
                        )
                }

                baselineP50.append(
                    try required(
                        baseLatency.p50Microseconds,
                        name: "p50"
                    )
                )
                candidateP50.append(
                    try required(
                        candidateLatency
                            .p50Microseconds,
                        name: "p50"
                    )
                )
                baselineP90.append(
                    try required(
                        baseLatency.p90Microseconds,
                        name: "p90"
                    )
                )
                candidateP90.append(
                    try required(
                        candidateLatency
                            .p90Microseconds,
                        name: "p90"
                    )
                )
                baselineP99.append(
                    try required(
                        baseLatency.p99Microseconds,
                        name: "p99"
                    )
                )
                candidateP99.append(
                    try required(
                        candidateLatency
                            .p99Microseconds,
                        name: "p99"
                    )
                )
                baselineP99_999.append(
                    try required(
                        baseLatency
                            .p99_999Microseconds,
                        name: "p99.999"
                    )
                )
                candidateP99_999.append(
                    try required(
                        candidateLatency
                            .p99_999Microseconds,
                        name: "p99.999"
                    )
                )
                baselineMax.append(
                    try required(
                        baseLatency
                            .maximumMicroseconds,
                        name: "max"
                    )
                )
                candidateMax.append(
                    try required(
                        candidateLatency
                            .maximumMicroseconds,
                        name: "max"
                    )
                )

                let baseResources =
                    try baseline.resources(
                        round: round,
                        route: route,
                        concurrency: concurrency
                    )
                let candidateResources =
                    try candidate.resources(
                        round: round,
                        route: route,
                        concurrency: concurrency
                    )

                guard
                    let baseEfficiency =
                        baseResources
                            .completedRequestsPerCPUSecond,
                    let candidateEfficiency =
                        candidateResources
                            .completedRequestsPerCPUSecond
                else {
                    throw ComparisonFailure
                        .invalidSummary(
                            "Missing requests/CPU-second"
                        )
                }

                baselineCPU.append(
                    baseEfficiency
                )
                candidateCPU.append(
                    candidateEfficiency
                )
                baselineRSS.append(
                    Double(
                        baseResources
                            .sampledPeakAggregateRSSKiB
                    )
                )
                candidateRSS.append(
                    Double(
                        candidateResources
                            .sampledPeakAggregateRSSKiB
                    )
                )
            }

            cells.append(
                CellReport(
                    path: route.path,
                    role: route.role,
                    concurrency: concurrency,
                    metrics: MetricSet(
                        requestsPerSecond:
                            try .init(
                                baseline: baselineRPS,
                                candidate:
                                    candidateRPS
                            ),
                        p50Microseconds:
                            try .init(
                                baseline: baselineP50,
                                candidate:
                                    candidateP50
                            ),
                        p90Microseconds:
                            try .init(
                                baseline: baselineP90,
                                candidate:
                                    candidateP90
                            ),
                        p99Microseconds:
                            try .init(
                                baseline: baselineP99,
                                candidate:
                                    candidateP99
                            ),
                        p99_999Microseconds:
                            try .init(
                                baseline:
                                    baselineP99_999,
                                candidate:
                                    candidateP99_999
                            ),
                        maximumMicroseconds:
                            try .init(
                                baseline: baselineMax,
                                candidate:
                                    candidateMax
                            ),
                        requestsPerCPUSecond:
                            try .init(
                                baseline: baselineCPU,
                                candidate:
                                    candidateCPU
                            ),
                        sampledPeakAggregateRSSKiB:
                            try .init(
                                baseline: baselineRSS,
                                candidate:
                                    candidateRSS
                            )
                    )
                )
            )
        }
    }

    return ComparisonReport(
        schemaVersion: 1,
        baselineHead: baseline.head,
        candidateHead: candidate.head,
        serverProduct:
            baseline.configuration.serverProduct,
        host: baseline.host,
        swiftVersion: baseline.swiftVersion,
        rounds: baseline.configuration.rounds,
        cells: cells
    )
}

do {
    let arguments =
        Array(CommandLine.arguments.dropFirst())

    guard arguments.count == 2 else {
        throw ComparisonFailure.invalidArguments
    }

    let baseline =
        try CampaignInput(path: arguments[0])
    let candidate =
        try CampaignInput(path: arguments[1])
    let report =
        try compare(
            baseline: baseline,
            candidate: candidate
        )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted,
        .sortedKeys,
    ]

    FileHandle.standardOutput.write(
        try encoder.encode(report)
    )
    print("")
} catch {
    FileHandle.standardError.write(
        Data(
            (
                "Cannot compare response-stream campaigns: "
                + "\(error)\n"
                + "Usage: whitethroated-benchmark-ab-compare "
                + "<baseline-dir> <candidate-dir>\n"
            ).utf8
        )
    )
    exit(1)
}
