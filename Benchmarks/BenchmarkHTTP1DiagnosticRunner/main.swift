import Foundation

private struct Metrics {
    let requestsPerSecond: Double
    let p50Microseconds: Double?
    let p90Microseconds: Double?
    let p99Microseconds: Double?
}

private struct SampleKey: Hashable {
    let server: String
    let path: String
}

private struct Samples {
    var throughput: [Double] = []
    var p50: [Double] = []
    var p90: [Double] = []
    var p99: [Double] = []
}

private enum RunnerError: Error, CustomStringConvertible {
    case invalidOutput(String)
    case processFailed(String, Int32, String)

    var description: String {
        switch self {
        case .invalidOutput(let output):
            return "Could not parse benchmark client output: \(output)"
        case .processFailed(let command, let status, let output):
            return "\(command) failed with status \(status): \(output)"
        }
    }
}

private let environment = ProcessInfo.processInfo.environment
private let root = environment["WHITETHROATED_HTTP1_DIAGNOSTIC_ROOT"]
    ?? FileManager.default.currentDirectoryPath
private let releaseDirectory = URL(
    fileURLWithPath: root,
    isDirectory: true
).appendingPathComponent(".build/release")

private let requests = positiveInt(
    environment["WHITETHROATED_HTTP1_DIAGNOSTIC_REQUESTS"],
    defaultValue: 100_000
)
private let warmupRequests = positiveInt(
    environment["WHITETHROATED_HTTP1_DIAGNOSTIC_WARMUP"],
    defaultValue: 10_000
)
private let connections = positiveInt(
    environment["WHITETHROATED_HTTP1_DIAGNOSTIC_CONNECTIONS"],
    defaultValue: 64
)
private let threads = positiveInt(
    environment["WHITETHROATED_HTTP1_DIAGNOSTIC_THREADS"],
    defaultValue: 2
)
private let rounds = positiveInt(
    environment["WHITETHROATED_HTTP1_DIAGNOSTIC_ROUNDS"],
    defaultValue: 3
)
private let port = positiveInt(
    environment["WHITETHROATED_HTTP1_DIAGNOSTIC_PORT"],
    defaultValue: 38180
)

private let servers = [
    "raw-nio-benchmark-server",
    "custom-http1-benchmark-server"
]
private let paths = ["/", "/json", "/user/42"]

private func positiveInt(
    _ value: String?,
    defaultValue: Int
) -> Int {
    guard
        let value,
        let parsed = Int(value),
        parsed > 0
    else {
        return defaultValue
    }

    return parsed
}

private func benchmarkEnvironment(
    path: String,
    requests: Int,
    latency: Bool
) -> [String: String] {
    [
        "WHITETHROATED_BENCH_HOST": "127.0.0.1",
        "WHITETHROATED_BENCH_PORT": String(port),
        "WHITETHROATED_BENCH_METHOD": "GET",
        "WHITETHROATED_BENCH_PATH": path,
        "WHITETHROATED_BENCH_CONNECTIONS": String(connections),
        "WHITETHROATED_BENCH_REQUESTS": String(requests),
        "WHITETHROATED_BENCH_THREADS": String(threads),
        "WHITETHROATED_BENCH_LATENCY": latency ? "1" : "0"
    ]
}

private func runClient(
    path: String,
    requests: Int,
    latency: Bool
) throws -> Metrics {
    let executable = releaseDirectory.appendingPathComponent(
        "whitethroated-benchmark-client"
    )

    let process = Process()
    process.executableURL = executable
    process.environment = environment.merging(
        benchmarkEnvironment(
            path: path,
            requests: requests,
            latency: latency
        )
    ) { _, value in value }

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(
        decoding: data,
        as: UTF8.self
    )

    guard process.terminationStatus == 0 else {
        throw RunnerError.processFailed(
            executable.lastPathComponent,
            process.terminationStatus,
            output
        )
    }

    guard
        let rps = value(
            named: "requests_per_second",
            in: output
        )
    else {
        throw RunnerError.invalidOutput(output)
    }

    if !latency {
        return Metrics(
            requestsPerSecond: rps,
            p50Microseconds: nil,
            p90Microseconds: nil,
            p99Microseconds: nil
        )
    }

    guard
        let p50 = value(
            named: "latency_p50_us",
            in: output
        ),
        let p90 = value(
            named: "latency_p90_us",
            in: output
        ),
        let p99 = value(
            named: "latency_p99_us",
            in: output
        )
    else {
        throw RunnerError.invalidOutput(output)
    }

    return Metrics(
        requestsPerSecond: rps,
        p50Microseconds: p50,
        p90Microseconds: p90,
        p99Microseconds: p99
    )
}

private func value(
    named name: String,
    in output: String
) -> Double? {
    let prefix = name + "="

    for line in output.split(
        whereSeparator: \.isNewline
    ) {
        guard line.hasPrefix(prefix) else {
            continue
        }

        return Double(
            line.dropFirst(prefix.count)
        )
    }

    return nil
}

private func startServer(
    _ product: String
) throws -> Process {
    let executable = releaseDirectory.appendingPathComponent(
        product
    )

    let process = Process()
    process.executableURL = executable
    process.environment = environment.merging([
        "WHITETHROATED_HOST": "127.0.0.1",
        "WHITETHROATED_PORT": String(port),
        "WHITETHROATED_THREADS": String(threads)
    ]) { _, value in value }

    let null = FileHandle.nullDevice
    process.standardOutput = null
    process.standardError = null

    try process.run()
    Thread.sleep(forTimeInterval: 0.5)

    guard process.isRunning else {
        process.waitUntilExit()
        throw RunnerError.processFailed(
            product,
            process.terminationStatus,
            "server exited during startup"
        )
    }

    return process
}

private func stopServer(_ process: Process) {
    if process.isRunning {
        process.terminate()
    }
    process.waitUntilExit()
}

private func median(
    _ values: [Double]
) -> Double {
    let sorted = values.sorted()
    let midpoint = sorted.count / 2

    if sorted.count.isMultiple(of: 2) {
        return (
            sorted[midpoint - 1]
            + sorted[midpoint]
        ) / 2
    }

    return sorted[midpoint]
}

private func percentDelta(
    custom: Double,
    raw: Double
) -> Double {
    (custom / raw - 1) * 100
}

private var samples: [SampleKey: Samples] = [:]

print(
    "WhiteThroated custom HTTP/1 diagnostic"
)
print(
    "shared/virtualized hosts are diagnostic only; do not publish these values"
)
print(
    "rounds=\(rounds) requests=\(requests) warmup=\(warmupRequests) connections=\(connections) threads=\(threads)"
)

for round in 0..<rounds {
    let order =
        round.isMultiple(of: 2)
        ? servers
        : Array(servers.reversed())

    for server in order {
        let process = try startServer(server)

        for path in paths {
            _ = try runClient(
                path: path,
                requests: warmupRequests,
                latency: false
            )

            let throughput = try runClient(
                path: path,
                requests: requests,
                latency: false
            )
            let latency = try runClient(
                path: path,
                requests: requests,
                latency: true
            )

            let key = SampleKey(
                server: server,
                path: path
            )
            var current =
                samples[key]
                ?? Samples()

            current.throughput.append(
                throughput.requestsPerSecond
            )
            current.p50.append(
                latency.p50Microseconds!
            )
            current.p90.append(
                latency.p90Microseconds!
            )
            current.p99.append(
                latency.p99Microseconds!
            )
            samples[key] = current

            print(
                "round=\(round + 1) server=\(server) path=\(path) rps=\(Int(throughput.requestsPerSecond)) p50_us=\(latency.p50Microseconds!) p90_us=\(latency.p90Microseconds!) p99_us=\(latency.p99Microseconds!)"
            )
        }

        stopServer(process)
    }
}

print("")
print("median comparison")

for path in paths {
    let rawKey = SampleKey(
        server: servers[0],
        path: path
    )
    let customKey = SampleKey(
        server: servers[1],
        path: path
    )

    guard
        let raw = samples[rawKey],
        let custom = samples[customKey]
    else {
        continue
    }

    let rawRPS = median(raw.throughput)
    let customRPS = median(custom.throughput)
    let rawP50 = median(raw.p50)
    let customP50 = median(custom.p50)
    let rawP90 = median(raw.p90)
    let customP90 = median(custom.p90)
    let rawP99 = median(raw.p99)
    let customP99 = median(custom.p99)

    print(
        "path=\(path) metric=rps raw=\(Int(rawRPS)) custom=\(Int(customRPS)) delta_pct=\(String(format: "%.2f", percentDelta(custom: customRPS, raw: rawRPS)))"
    )
    print(
        "path=\(path) metric=p50_us raw=\(String(format: "%.3f", rawP50)) custom=\(String(format: "%.3f", customP50)) delta_pct=\(String(format: "%.2f", percentDelta(custom: customP50, raw: rawP50)))"
    )
    print(
        "path=\(path) metric=p90_us raw=\(String(format: "%.3f", rawP90)) custom=\(String(format: "%.3f", customP90)) delta_pct=\(String(format: "%.2f", percentDelta(custom: customP90, raw: rawP90)))"
    )
    print(
        "path=\(path) metric=p99_us raw=\(String(format: "%.3f", rawP99)) custom=\(String(format: "%.3f", customP99)) delta_pct=\(String(format: "%.2f", percentDelta(custom: customP99, raw: rawP99)))"
    )
}
