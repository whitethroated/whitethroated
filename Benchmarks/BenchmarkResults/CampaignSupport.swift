import Foundation

public enum CampaignError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let message): return message }
    }
}


public enum CampaignProfile: String, Codable, Sendable {
    case rest
    case responseStream = "response-stream"
}

public struct CampaignConfiguration: Codable, Sendable {
    public let root: String
    public let output: String
    public let serverProduct: String
    public let basePort: Int
    public let smoke: Bool
    public let profile: CampaignProfile

    public var rounds: Int {
        if smoke {
            return 1
        }

        return profile == .responseStream ? 3 : 5
    }

    public var concurrencies: [Int] {
        if smoke {
            return [64]
        }

        return profile == .responseStream
            ? [64, 512]
            : [64, 256, 512]
    }

    public var requestsPerShard: Int {
        smoke ? 8_000 : 125_000
    }

    public var warmupRequests: Int {
        smoke ? 1_000 : 10_000
    }

    public var shards: Int {
        profile == .responseStream ? 4 : 8
    }

    public var serverLoops: Int {
        profile == .responseStream ? 2 : 8
    }

    public init(environment: [String: String], currentDirectory: String) throws {
        root = environment["WHITETHROATED_CAMPAIGN_ROOT"] ?? currentDirectory
        guard let output = environment["WHITETHROATED_CAMPAIGN_OUTPUT"],
              output.hasPrefix("/"), root.hasPrefix("/") else {
            throw CampaignError.invalid("Set WHITETHROATED_CAMPAIGN_OUTPUT to a fresh absolute directory")
        }
        self.output = output
        serverProduct = environment["WHITETHROATED_CAMPAIGN_SERVER"] ?? "whitethroated-benchmark-server"
        guard ["whitethroated-benchmark-server", "whitethroated-runtime-benchmark-server", "raw-nio-benchmark-server"].contains(serverProduct) else {
            throw CampaignError.invalid("Unsupported Swift control product")
        }
        let portText = environment["WHITETHROATED_CAMPAIGN_PORT"] ?? "3310"
        guard let port = Int(portText), (1024...65531).contains(port) else {
            throw CampaignError.invalid("Invalid campaign base port")
        }
        basePort = port
        let smokeText = environment["WHITETHROATED_CAMPAIGN_SMOKE"] ?? "0"
        guard smokeText == "0" || smokeText == "1" else {
            throw CampaignError.invalid("SMOKE must be 0 or 1")
        }
        smoke = smokeText == "1"

        let profileText =
            environment["WHITETHROATED_CAMPAIGN_PROFILE"]
            ?? CampaignProfile.rest.rawValue
        guard let profile = CampaignProfile(rawValue: profileText) else {
            throw CampaignError.invalid(
                "PROFILE must be rest or response-stream"
            )
        }
        self.profile = profile
    }
}

/// Parses cumulative CPU times emitted by ps, including Linux day prefixes.
/// RSS is KiB on the supported macOS/Linux ps implementations.
public struct WorkerObservation: Codable, Sendable {
    public let pid: Int32
    public let rssKiB: Int
    public let cpuSeconds: Double

    public static func parse(_ text: String) throws -> [WorkerObservation] {
        try text.split(whereSeparator: \.isNewline).map { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 0,
                  let rss = Int(fields[1]), rss >= 0 else {
                throw CampaignError.invalid("Invalid ps worker observation")
            }
            return WorkerObservation(pid: pid, rssKiB: rss, cpuSeconds: try cpuTime(String(fields[2])))
        }
    }

    public static func cpuTime(_ value: String) throws -> Double {
        let dayParts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard dayParts.count <= 2 else { throw CampaignError.invalid("Invalid ps CPU time") }
        var days = 0
        if dayParts.count == 2 {
            guard let parsed = Int(dayParts[0]), parsed >= 0 else {
                throw CampaignError.invalid("Invalid ps CPU days")
            }
            days = parsed
        }
        let parts = dayParts.last!.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let seconds = Double(parts.last!), seconds.isFinite, seconds >= 0, seconds < 60,
              let minutes = Int(parts[parts.count - 2]), minutes >= 0,
              (parts.count == 2 || minutes < 60) else {
            throw CampaignError.invalid("Invalid ps CPU time components")
        }
        var hours = 0
        if parts.count == 3 {
            guard let parsed = Int(parts[0]), parsed >= 0 else {
                throw CampaignError.invalid("Invalid ps CPU hours")
            }
            hours = parsed
        }
        return Double(days) * 86400 + Double(hours) * 3600 + Double(minutes) * 60 + seconds
    }
}

public struct ResourceObservation: Codable, Sendable {
    public let uptimeNanoseconds: UInt64
    public let workers: [WorkerObservation]
    public init(uptimeNanoseconds: UInt64, workers: [WorkerObservation]) {
        self.uptimeNanoseconds = uptimeNanoseconds
        self.workers = workers
    }
}

public struct ResourceSummary: Codable, Sendable {
    public let initialRSSKiB: Int
    public let postRSSKiB: Int
    public let sampledPeakAggregateRSSKiB: Int
    public let cpuSeconds: Double
    public let observationSeconds: Double
    public let cpuPercent: Double
    public let completedRequestsPerCPUSecond: Double?

    public init(observations: [ResourceObservation], completed: Int) throws {
        guard let first = observations.first, let last = observations.last,
              !first.workers.isEmpty, completed > 0,
              last.uptimeNanoseconds > first.uptimeNanoseconds else {
            throw CampaignError.invalid("Insufficient resource observations")
        }
        let pids = Set(first.workers.map(\.pid))
        guard pids.count == first.workers.count else { throw CampaignError.invalid("Duplicate worker PID") }
        var previous = first
        for observation in observations {
            guard observation.uptimeNanoseconds >= previous.uptimeNanoseconds,
                  Set(observation.workers.map(\.pid)) == pids,
                  observation.workers.count == pids.count else {
                throw CampaignError.invalid("Worker set or observation ordering changed")
            }
            for worker in observation.workers {
                guard worker.cpuSeconds >= previous.workers.first(where: { $0.pid == worker.pid })!.cpuSeconds else {
                    throw CampaignError.invalid("Cumulative worker CPU decreased")
                }
            }
            previous = observation
        }
        initialRSSKiB = first.workers.reduce(0) { $0 + $1.rssKiB }
        postRSSKiB = last.workers.reduce(0) { $0 + $1.rssKiB }
        sampledPeakAggregateRSSKiB = observations.map { $0.workers.reduce(0) { $0 + $1.rssKiB } }.max()!
        cpuSeconds = last.workers.reduce(0) { $0 + $1.cpuSeconds } - first.workers.reduce(0) { $0 + $1.cpuSeconds }
        observationSeconds = Double(last.uptimeNanoseconds - first.uptimeNanoseconds) / 1_000_000_000
        cpuPercent = cpuSeconds / observationSeconds * 100
        completedRequestsPerCPUSecond = cpuSeconds > 0 ? Double(completed) / cpuSeconds : nil
    }
}
