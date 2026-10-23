import BenchmarkResults
import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

private final class Cancellation: @unchecked Sendable {
    // Dispatch signal callbacks and the driver share only this lock-protected bit.
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private struct HostObservation: Codable {
    let at: Date
    let load: [Double]
    let memoryState: String
    let memoryOK: Bool
    let externalCPUPercent: Double
    let quiet: Bool
}

private struct CommandFailure: Error, CustomStringConvertible {
    let status: Int32
    let description: String
}

private struct CampaignVariant {
    let name: String
    let root: String
    let directory: URL
    let binaries: URL
    let head: String
    let worktreeDiff: String
    let packageResolved: String
}

private final class Campaign {
    let configuration: CampaignConfiguration
    let cancellation: Cancellation
    var children: [Process] = []
    var baseline = ""
    var outputCreated = false
    var activeVariant: CampaignVariant?
    var pairedClientBinaries: URL?
    let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    var directory: URL {
        URL(
            fileURLWithPath: configuration.output,
            isDirectory: true
        )
    }

    var binaries: URL {
        URL(
            fileURLWithPath: configuration.root,
            isDirectory: true
        ).appendingPathComponent(".build/release")
    }

    var activeDirectory: URL {
        activeVariant?.directory ?? directory
    }

    var activeBinaries: URL {
        activeVariant?.binaries ?? binaries
    }

    var clientBinaries: URL {
        pairedClientBinaries ?? activeBinaries
    }

    var activeRoot: String {
        activeVariant?.root ?? configuration.root
    }

    var activeHead: String {
        activeVariant?.head ?? baseline
    }

    init(configuration: CampaignConfiguration, cancellation: Cancellation) {
        self.configuration = configuration
        self.cancellation = cancellation
    }

    func capture(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, value in value }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(status: process.terminationStatus,
                                 description: "Command failed: \(executable) \(arguments.joined(separator: " ")): \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func save<T: Encodable>(
        _ value: T,
        _ name: String,
        to targetDirectory: URL
    ) throws {
        try encoder.encode(value).write(
            to: targetDirectory.appendingPathComponent(name),
            options: .atomic
        )
    }

    func save<T: Encodable>(_ value: T, _ name: String) throws {
        try save(value, name, to: activeDirectory)
    }

    func saveText(
        _ value: String,
        _ name: String,
        to targetDirectory: URL
    ) throws {
        try Data(value.utf8).write(
            to: targetDirectory.appendingPathComponent(name),
            options: .atomic
        )
    }

    func saveText(_ value: String, _ name: String) throws {
        try saveText(value, name, to: activeDirectory)
    }

    func checkBaseline() throws {
        guard !cancellation.cancelled else {
            throw CampaignError.invalid("Interrupted")
        }

        let current = try capture(
            "/usr/bin/git",
            ["-C", activeRoot, "rev-parse", "HEAD"]
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard current == activeHead else {
            throw CampaignError.invalid(
                "HEAD changed for \(activeRoot); stop and reconcile baseline"
            )
        }
    }

    func host() throws -> HostObservation {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { throw CampaignError.invalid("Host load unavailable") }
        let limit = Double(ProcessInfo.processInfo.activeProcessorCount) / 2
        let memory: String
        let memoryOK: Bool
        #if os(macOS)
        memory = try capture("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"]).trimmingCharacters(in: .whitespacesAndNewlines)
        memoryOK = memory == "1"
        #else
        memory = try String(contentsOfFile: "/proc/meminfo", encoding: .utf8)
        func kib(_ key: String) -> Double? {
            memory.split(separator: "\n").first(where: { $0.hasPrefix(key + ":") })
                .flatMap { Double($0.split(whereSeparator: \.isWhitespace)[1]) }
        }
        guard let total = kib("MemTotal"), let available = kib("MemAvailable"), total > 0 else {
            throw CampaignError.invalid("Linux memory availability unavailable")
        }
        memoryOK = available / total >= 0.1
        #endif
        let processText = try capture("/bin/ps", ["-A", "-o", "pid=,pcpu="])
        let owned = Set(children.map(\.processIdentifier) + [getpid()])
        var externalCPU = 0.0
        for line in processText.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let cpu = Double(fields[1]), cpu.isFinite, cpu >= 0 else {
                throw CampaignError.invalid("External CPU observation unavailable")
            }
            if !owned.contains(pid) { externalCPU += cpu }
        }
        // Load averages contain our own preceding cells. Use them only for
        // initial admission; between cells check memory and unrelated CPU.
        let loadOK = load[0] <= limit && load[1] <= limit
        return HostObservation(at: Date(), load: load, memoryState: memory, memoryOK: memoryOK, externalCPUPercent: externalCPU,
                               quiet: memoryOK && externalCPU <= 100 && loadOK)
    }

    func gate(_ name: String) throws {
        try checkBaseline()
        let observation = try host()
        try save(observation, name + "-host.json")
        let admitted = name == "preflight" ? observation.quiet : observation.memoryOK && observation.externalCPUPercent <= 100
        guard configuration.smoke || admitted else {
            throw CampaignError.invalid("Quiet-host gate failed (load \(observation.load), memory \(observation.memoryState)); results are incomplete, do not publish")
        }
    }

    func spawn(_ executable: URL, _ arguments: [String] = [], environment: [String: String] = [:], log: String) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Optional route/middleware flags from a developer terminal must not
        // silently alter the default contract or worker/client loop counts.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("WHITETHROATED_") }
            .merging(environment) { _, value in value }
        let url = activeDirectory.appendingPathComponent(log)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CampaignError.invalid("Could not create child log")
        }
        let handle = try FileHandle(forWritingTo: url)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        children.append(process)
        return process
    }

    func stop(_ processes: [Process]) {
        for process in processes where process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while processes.contains(where: \.isRunning) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        for process in processes where process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        for process in processes { process.waitUntilExit() }
        let identifiers = Set(processes.map(\.processIdentifier))
        children.removeAll { identifiers.contains($0.processIdentifier) }
    }

    func wait(_ processes: [Process], timeout: TimeInterval = 120) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while processes.contains(where: \.isRunning) {
            guard !cancellation.cancelled, Date() < deadline else {
                throw CampaignError.invalid("Child timeout/interruption; cell invalid")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        for process in processes {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CampaignError.invalid("Child failed; inspect logs") }
        }
        let identifiers = Set(processes.map(\.processIdentifier))
        children.removeAll { identifiers.contains($0.processIdentifier) }
    }

    func observe(_ workers: [Process]) throws -> ResourceObservation {
        guard workers.allSatisfy(\.isRunning) else { throw CampaignError.invalid("Campaign worker exited") }
        let pids = workers.map { String($0.processIdentifier) }.joined(separator: ",")
        let text = try capture("/bin/ps", ["-o", "pid=,rss=,time=", "-p", pids])
        let observations = try WorkerObservation.parse(text)
        guard Set(observations.map(\.pid)) == Set(workers.map(\.processIdentifier)) else {
            throw CampaignError.invalid("Worker missing from resource observation")
        }
        return ResourceObservation(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, workers: observations)
    }

    func requireFreePort(_ port: Int) throws {
        #if os(macOS)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw CampaignError.invalid("Cannot check benchmark port") }
        defer { _ = close(descriptor) }
        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
            throw CampaignError.invalid("Cannot configure port availability check")
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        // Standard C socket interop during setup only; no request-path pointers.
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw CampaignError.invalid("Benchmark port \(port) is unavailable") }
    }

    func clientEnvironment(port: Int, method: String, path: String, connections: Int, requests: Int) -> [String: String] {
        ["WHITETHROATED_BENCH_HOST": "127.0.0.1", "WHITETHROATED_BENCH_PORT": String(port),
         "WHITETHROATED_BENCH_METHOD": method, "WHITETHROATED_BENCH_PATH": path,
         "WHITETHROATED_BENCH_CONNECTIONS": String(connections), "WHITETHROATED_BENCH_REQUESTS": String(requests),
         "WHITETHROATED_BENCH_THREADS": "1", "WHITETHROATED_BENCH_TCP_NODELAY": "1"]
    }

    func verify(worker: Process, port: Int, method: String, path: String, name: String) throws {
        let body = activeDirectory.appendingPathComponent(name + "-body.txt")
        let headers = activeDirectory.appendingPathComponent(name + "-headers.txt")
        let arguments = ["--http1.1", "--silent", "--show-error", "--max-time", "3",
            "--request", method, "--output", body.path, "--dump-header", headers.path, "--write-out", "%{http_code}",
            "http://127.0.0.1:\(port)\(path)"]
        let deadline = Date().addingTimeInterval(30)
        var status: String
        while true {
            guard !cancellation.cancelled, worker.isRunning else { throw CampaignError.invalid("Worker exited/interrupted during readiness") }
            do {
                status = try capture("/usr/bin/curl", arguments)
                break
            } catch let error as CommandFailure {
                // Only connection-refused startup retries; never retry a bad
                // HTTP status, payload, framing or a response timeout.
                guard error.status == 7, Date() < deadline else { throw error }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let expected = path == "/user/42" ? "42" : ""
        guard status == "200", try Data(contentsOf: body) == Data(expected.utf8) else {
            throw CampaignError.invalid("Response status/body contract mismatch")
        }
        let text = try String(contentsOf: headers, encoding: .utf8)
        let fields = text.components(separatedBy: "\r\n").compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let lengths = fields.filter { $0.0 == "content-length" }.map(\.1)
        guard lengths == [String(expected.utf8.count)],
              !fields.contains(where: { $0.0 == "transfer-encoding" }),
              (expected.isEmpty || fields.filter { $0.0 == "content-type" }.map(\.1) == ["text/plain; charset=utf-8"]) else {
            throw CampaignError.invalid("Response framing/content-type contract mismatch")
        }
    }

    func runCell(
        workers: [Process],
        method: String,
        path: String,
        concurrency: Int,
        mode: String,
        id: String,
        shards: Int = 8
    ) throws {
        guard workers.allSatisfy(\.isRunning) else { throw CampaignError.invalid("Campaign worker exited") }
        try gate(id + "-before")
        var observations: [ResourceObservation] = []
        if mode == "resource" { observations.append(try observe(workers)) }
        var clients: [Process] = []
        var files: [URL] = []
        guard concurrency.isMultiple(of: shards) else {
            throw CampaignError.invalid("Concurrency must divide evenly across shards")
        }
        for shard in 0..<shards {
            let file = activeDirectory.appendingPathComponent(id + "-shard-\(shard).json")
            files.append(file)
            var env = clientEnvironment(port: configuration.basePort + shard % workers.count, method: method, path: path,
                                        connections: concurrency / shards, requests: configuration.requestsPerShard)
            env["WHITETHROATED_BENCH_LATENCY"] = mode == "latency" ? "1" : "0"
            env["WHITETHROATED_BENCH_RUN_ID"] = id
            env["WHITETHROATED_BENCH_OUTPUT"] = file.path
            clients.append(try spawn(activeBinaries.appendingPathComponent("whitethroated-benchmark-client"),
                                    environment: env, log: id + "-shard-\(shard).log"))
        }
        if mode == "resource" {
            let deadline = Date().addingTimeInterval(120)
            while clients.contains(where: \.isRunning) {
                guard !cancellation.cancelled, Date() < deadline else { throw CampaignError.invalid("Resource cell timeout/interruption") }
                observations.append(try observe(workers))
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        try wait(clients)
        guard workers.allSatisfy(\.isRunning) else { throw CampaignError.invalid("Campaign worker exited during load") }
        if mode == "resource" { observations.append(try observe(workers)) }
        try checkBaseline()
        let samples = try files.map { try JSONDecoder().decode(BenchmarkSample.self, from: Data(contentsOf: $0)) }
        let summary = try BenchmarkSummary(samples: samples)
        guard summary.completed == configuration.requestsPerShard * shards, summary.connections == concurrency else {
            throw CampaignError.invalid("Unexpected aggregate request/connection count")
        }
        try save(summary, id + "-pooled.json")
        if mode == "resource" {
            try save(observations, id + "-observations.json")
            try save(ResourceSummary(observations: observations, completed: summary.completed), id + "-resources.json")
        }
        // Check host only after *all* clients have exited, including export work.
        try gate(id + "-after")
        print("completed \(id)")
        // Flush progress without accessing Glibc's mutable stdout global.
        fflush(nil)
    }

    func verifyResponseStream(
        worker: Process,
        port: Int,
        path: String,
        chunked: Bool,
        name: String
    ) throws {
        let body = activeDirectory.appendingPathComponent(
            name + "-body.txt"
        )
        let headers = activeDirectory.appendingPathComponent(
            name + "-headers.txt"
        )
        let arguments = [
            "--http1.1",
            "--silent",
            "--show-error",
            "--max-time",
            "3",
            "--request",
            "GET",
            "--output",
            body.path,
            "--dump-header",
            headers.path,
            "--write-out",
            "%{http_code}",
            "http://127.0.0.1:\(port)\(path)",
        ]
        let deadline = Date().addingTimeInterval(30)
        var status: String

        while true {
            guard
                !cancellation.cancelled,
                worker.isRunning
            else {
                throw CampaignError.invalid(
                    "Worker exited/interrupted during readiness"
                )
            }

            do {
                status = try capture(
                    "/usr/bin/curl",
                    arguments
                )
                break
            } catch let error as CommandFailure {
                guard
                    error.status == 7,
                    Date() < deadline
                else {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        guard
            status == "200",
            try Data(contentsOf: body)
                == Data("Hello, World!".utf8)
        else {
            throw CampaignError.invalid(
                "Response status/body contract mismatch"
            )
        }

        let text = try String(
            contentsOf: headers,
            encoding: .utf8
        )
        let fields = text
            .components(separatedBy: "\r\n")
            .compactMap {
                line -> (String, String)? in
                guard
                    let colon = line.firstIndex(of: ":")
                else {
                    return nil
                }
                return (
                    line[..<colon].lowercased(),
                    line[
                        line.index(after: colon)...
                    ].trimmingCharacters(
                        in: .whitespaces
                    )
                )
            }
        let lengths = fields
            .filter { $0.0 == "content-length" }
            .map(\.1)
        let transfers = fields
            .filter { $0.0 == "transfer-encoding" }
            .map { $0.1.lowercased() }
        let contentTypes = fields
            .filter { $0.0 == "content-type" }
            .map(\.1)

        guard
            contentTypes
                == ["text/plain; charset=utf-8"]
        else {
            throw CampaignError.invalid(
                "Response content-type contract mismatch"
            )
        }

        if chunked {
            guard
                lengths.isEmpty,
                transfers == ["chunked"]
            else {
                throw CampaignError.invalid(
                    "Response chunked framing mismatch"
                )
            }
        } else {
            guard
                lengths == ["13"],
                transfers.isEmpty
            else {
                throw CampaignError.invalid(
                    "Response content-length framing mismatch"
                )
            }
        }
    }

    func runResponseStreamProfile() throws {
        typealias Route = (
            path: String,
            label: String,
            chunked: Bool
        )

        let baseRoutes: [Route] = [
            (
                "/response-stream-known",
                "stream-known",
                false
            ),
            (
                "/response-stream",
                "stream-chunked",
                true
            ),
            (
                "/response-stream-ab-known",
                "stream-ab-known",
                false
            ),
            (
                "/response-stream-ab",
                "stream-ab-chunked",
                true
            ),
            (
                "/response-stream-flush",
                "stream-flush",
                true
            ),
        ]

        for round in 1...configuration.rounds {
            let offset =
                (round - 1) % baseRoutes.count
            let routes =
                Array(baseRoutes[offset...])
                + Array(baseRoutes[..<offset])
            let concurrencies =
                round.isMultiple(of: 2)
                ? Array(
                    configuration
                        .concurrencies
                        .reversed()
                )
                : configuration.concurrencies
            let prefix = "r\(round)-1x2"

            try gate(prefix)
            try requireFreePort(
                configuration.basePort
            )

            let worker = try spawn(
                activeBinaries.appendingPathComponent(
                    configuration.serverProduct
                ),
                environment: [
                    "WHITETHROATED_HOST":
                        "127.0.0.1",
                    "WHITETHROATED_PORT":
                        String(
                            configuration.basePort
                        ),
                    "WHITETHROATED_THREADS": "2",
                    "WHITETHROATED_RESPONSE_STREAM_BENCHMARKS":
                        "1",
                ],
                log: prefix + "-worker-0.log"
            )
            var workers = [worker]
            defer {
                stop(workers)
            }

            for route in routes {
                try verifyResponseStream(
                    worker: worker,
                    port: configuration.basePort,
                    path: route.path,
                    chunked: route.chunked,
                    name:
                        prefix
                        + "-verify-"
                        + route.label
                )
            }

            try save(
                try observe(workers),
                prefix + "-idle.json"
            )

            for route in routes {
                let warm = try spawn(
                    activeBinaries.appendingPathComponent(
                        "whitethroated-benchmark-client"
                    ),
                    environment:
                        clientEnvironment(
                            port:
                                configuration.basePort,
                            method: "GET",
                            path: route.path,
                            connections: 8,
                            requests:
                                configuration
                                .warmupRequests
                        ),
                    log:
                        prefix
                        + "-warm-"
                        + route.label
                        + ".log"
                )
                try wait(
                    [warm],
                    timeout: 30
                )
            }

            for route in routes {
                for concurrency in
                    concurrencies
                {
                    for mode in [
                        "throughput",
                        "latency",
                        "resource",
                    ] {
                        let id =
                            prefix
                            + "-"
                            + route.label
                            + "-c\(concurrency)-"
                            + mode

                        try runCell(
                            workers: workers,
                            method: "GET",
                            path: route.path,
                            concurrency:
                                concurrency,
                            mode: mode,
                            id: id,
                            shards:
                                configuration.shards
                        )
                    }
                }
            }
        }
    }

    func run() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CampaignError.invalid("Campaign output already exists; use a fresh directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        outputCreated = true
        try save(configuration, "configuration.json")
        let topologyCount =
            configuration.profile == .responseStream ? 1 : 2
        let routeCount =
            configuration.profile == .responseStream ? 5 : 3
        try save([
            "rounds": configuration.rounds,
            "shards": configuration.shards,
            "serverLoops": configuration.serverLoops,
            "clientThreadsPerShard": 1,
            "requestsPerShard": configuration.requestsPerShard,
            "warmupRequestsPerWorkerRoute": configuration.warmupRequests,
            "cellCount":
                configuration.rounds
                * topologyCount
                * routeCount
                * configuration.concurrencies.count
                * 3
        ], "plan.json")
        baseline = try capture("/usr/bin/git", ["-C", configuration.root, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try saveText(baseline, "head.txt")
        try saveText(try capture("/usr/bin/git", ["-C", configuration.root, "diff", "HEAD"]), "worktree.diff")
        try saveText(try capture("/usr/bin/env", ["swift", "--version"]), "swift-version.txt")
        try saveText(try capture("/usr/bin/uname", ["-a"]), "host.txt")
        try saveText(try String(contentsOfFile: configuration.root + "/Package.resolved", encoding: .utf8), "Package.resolved.txt")
        try gate("preflight")
        for product in [configuration.serverProduct, "whitethroated-benchmark-client"] {
            guard FileManager.default.isExecutableFile(atPath: activeBinaries.appendingPathComponent(product).path) else {
                throw CampaignError.invalid("Build release product before campaign: \(product)")
            }
        }
        if configuration.profile == .responseStream {
            try runResponseStreamProfile()
            try saveText(
                configuration.smoke
                    ? "SMOKE ONLY — no performance claims\n"
                    : "Complete; inspect variance and gates before claims\n",
                "COMPLETE.txt"
            )
            return
        }

        let routes = [("GET", "/", "root"), ("GET", "/user/42", "parameter"), ("POST", "/user", "post")]
        for round in 1...configuration.rounds {
            for workerCount in (round.isMultiple(of: 2) ? [4, 1] : [1, 4]) {
                let prefix = "r\(round)-\(workerCount)x\(8 / workerCount)"
                try gate(prefix)
                var workers: [Process] = []
                defer { stop(workers) }
                for worker in 0..<workerCount { try requireFreePort(configuration.basePort + worker) }
                for worker in 0..<workerCount {
                    workers.append(try spawn(activeBinaries.appendingPathComponent(configuration.serverProduct), environment: [
                        "WHITETHROATED_HOST": "127.0.0.1", "WHITETHROATED_PORT": String(configuration.basePort + worker),
                        "WHITETHROATED_THREADS": String(8 / workerCount)
                    ], log: prefix + "-worker-\(worker).log"))
                }
                for worker in 0..<workerCount {
                    for (method, path, label) in routes {
                        try verify(worker: workers[worker], port: configuration.basePort + worker, method: method, path: path,
                                   name: prefix + "-verify-\(worker)-" + label)
                    }
                }
                try save(try observe(workers), prefix + "-idle.json")
                for worker in 0..<workerCount {
                    for (method, path, label) in routes {
                        let warm = try spawn(activeBinaries.appendingPathComponent("whitethroated-benchmark-client"), environment:
                            clientEnvironment(port: configuration.basePort + worker, method: method, path: path,
                                              connections: 8, requests: configuration.warmupRequests),
                            log: prefix + "-warm-\(worker)-" + label + ".log")
                        try wait([warm], timeout: 30)
                    }
                }
                for (method, path, label) in routes {
                    for concurrency in configuration.concurrencies {
                        for mode in ["throughput", "latency", "resource"] {
                            let id = prefix + "-\(label)-c\(concurrency)-" + mode
                            try runCell(workers: workers, method: method, path: path, concurrency: concurrency, mode: mode, id: id)
                        }
                    }
                }
            }
        }
        try saveText(configuration.smoke ? "SMOKE ONLY — no performance claims\n" : "Complete; inspect variance and gates before claims\n", "COMPLETE.txt")
    }
}

private let cancellation = Cancellation()
private let signals = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    let flag = cancellation
    // Explicit Sendable prevents this top-level callback inheriting MainActor
    // isolation and trapping when libdispatch invokes it on the global queue.
    source.setEventHandler { @Sendable in flag.cancel() }
    source.resume()
    return source
}
private var campaign: Campaign?
do {
    let configuration = try CampaignConfiguration(environment: ProcessInfo.processInfo.environment,
                                                  currentDirectory: FileManager.default.currentDirectoryPath)
    let driver = Campaign(configuration: configuration, cancellation: cancellation)
    campaign = driver
    // Install and retain signal sources across all synchronous child waits.
    try withExtendedLifetime(signals) { try driver.run() }
    driver.stop(driver.children)
} catch {
    if let campaign {
        campaign.stop(campaign.children)
        if campaign.outputCreated { try? campaign.saveText("\(error)\n", "ABORTED.txt") }
    }
    FileHandle.standardError.write(Data("Campaign stopped: \(error)\n".utf8))
    exit(1)
}
