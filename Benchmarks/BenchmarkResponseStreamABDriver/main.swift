import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

private enum DriverError:
    Error,
    CustomStringConvertible
{
    case invalidArguments
    case invalidOutput(String)
    case commandFailed(String)
    case invalidEnvironment(String)
    case loadDidNotSettle

    var description: String {
        switch self {
        case .invalidArguments:
            return """
            Usage: whitethroated-response-stream-ab-driver \
              <baseline-ref> <candidate-ref> <absolute-output-directory>
            """

        case .invalidOutput(let message):
            return message

        case .commandFailed(let message):
            return message

        case .invalidEnvironment(let message):
            return message

        case .loadDidNotSettle:
            return "Host load did not settle before the benchmark admission window"
        }
    }
}

private struct LayerManifest: Codable {
    let name: String
    let serverProduct: String
    let campaignDirectory: String
    let comparisonFile: String
}

private struct DriverManifest: Codable {
    let schemaVersion: Int
    let baselineHead: String
    let candidateHead: String
    let repositoryRoot: String
    let swiftVersion: String
    let host: String
    let generatedAt: String
    let layers: [LayerManifest]
}

private struct Layer {
    let name: String
    let serverProduct: String
}

private let layers = [
    Layer(
        name: "framework",
        serverProduct:
            "whitethroated-benchmark-server"
    ),
    Layer(
        name: "runtime",
        serverProduct:
            "whitethroated-runtime-benchmark-server"
    ),
    Layer(
        name: "raw",
        serverProduct:
            "raw-nio-benchmark-server"
    ),
]

private func process(
    executable: String,
    arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil,
    captureOutput: Bool = false
) throws -> String {
    let process = Process()
    process.executableURL =
        URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL =
        currentDirectory

    if let environment {
        process.environment =
            ProcessInfo.processInfo.environment
                .merging(environment) {
                    _, value in value
                }
    }

    let pipe: Pipe?

    if captureOutput {
        let value = Pipe()
        process.standardOutput = value
        process.standardError = value
        pipe = value
    } else {
        pipe = nil
    }

    try process.run()

    let data: Data

    if let pipe {
        data =
            pipe.fileHandleForReading
                .readDataToEndOfFile()
    } else {
        data = Data()
    }

    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let output =
            String(
                decoding: data,
                as: UTF8.self
            )

        throw DriverError.commandFailed(
            (
                [executable] + arguments
            ).joined(separator: " ")
            + (output.isEmpty ? "" : "\n" + output)
        )
    }

    return String(
        decoding: data,
        as: UTF8.self
    )
}

private func git(
    _ arguments: [String],
    repository: URL,
    captureOutput: Bool = false
) throws -> String {
    try process(
        executable: "/usr/bin/env",
        arguments: ["git"] + arguments,
        currentDirectory: repository,
        captureOutput: captureOutput
    )
}

private func swift(
    _ arguments: [String],
    root: URL
) throws {
    _ = try process(
        executable: "/usr/bin/env",
        arguments: ["swift"] + arguments,
        currentDirectory: root
    )
}

private func resolveCommit(
    _ value: String,
    repository: URL
) throws -> String {
    try git(
        [
            "rev-parse",
            "--verify",
            value + "^{commit}",
        ],
        repository: repository,
        captureOutput: true
    ).trimmingCharacters(
        in: .whitespacesAndNewlines
    )
}

private func repositoryRoot() throws -> URL {
    let current = URL(
        fileURLWithPath:
            FileManager.default
                .currentDirectoryPath,
        isDirectory: true
    )

    let root = try git(
        [
            "rev-parse",
            "--show-toplevel",
        ],
        repository: current,
        captureOutput: true
    ).trimmingCharacters(
        in: .whitespacesAndNewlines
    )

    return URL(
        fileURLWithPath: root,
        isDirectory: true
    ).standardizedFileURL
}

private func requireFreshAbsoluteOutput(
    _ path: String,
    repository: URL
) throws -> URL {
    guard path.hasPrefix("/") else {
        throw DriverError.invalidOutput(
            "A/B output directory must be absolute"
        )
    }

    let url = URL(
        fileURLWithPath: path,
        isDirectory: true
    ).standardizedFileURL

    guard
        !FileManager.default
            .fileExists(atPath: url.path)
    else {
        throw DriverError.invalidOutput(
            "A/B output directory already exists: "
            + url.path
        )
    }

    let repositoryPath =
        repository.standardizedFileURL.path

    guard
        url.path != repositoryPath,
        !url.path.hasPrefix(
            repositoryPath + "/"
        )
    else {
        throw DriverError.invalidOutput(
            "A/B output directory must be outside the repository worktree"
        )
    }

    return url
}

private func build(
    products: [String],
    root: URL
) throws {
    for product in products {
        print(
            "building \(product) @ \(root.path)"
        )
        try swift(
            [
                "build",
                "-c",
                "release",
                "--product",
                product,
            ],
            root: root
        )
    }
}

private func waitForBuildLoadToSettle()
    throws
{
    let environment =
        ProcessInfo.processInfo.environment
    let timeoutText =
        environment[
            "WHITETHROATED_AB_LOAD_SETTLE_SECONDS"
        ] ?? "600"

    guard
        let timeoutSeconds =
            TimeInterval(timeoutText),
        timeoutSeconds >= 0
    else {
        throw DriverError.invalidEnvironment(
            "WHITETHROATED_AB_LOAD_SETTLE_SECONDS must be a non-negative number"
        )
    }

    guard timeoutSeconds > 0 else {
        return
    }

    let limit =
        Double(
            ProcessInfo.processInfo
                .activeProcessorCount
        ) / 2
    let deadline =
        Date().addingTimeInterval(
            timeoutSeconds
        )

    while true {
        var load = [Double](
            repeating: 0,
            count: 3
        )

        guard getloadavg(&load, 3) == 3 else {
            throw DriverError.invalidEnvironment(
                "Host load average is unavailable"
            )
        }

        if
            load[0] <= limit,
            load[1] <= limit
        {
            return
        }

        guard Date() < deadline else {
            throw DriverError.loadDidNotSettle
        }

        print(
            "waiting for build load to settle: "
            + "1m=\(load[0]) 5m=\(load[1]) "
            + "limit=\(limit)"
        )
        Thread.sleep(
            forTimeInterval: 5
        )
    }
}

private func write(
    _ string: String,
    to url: URL
) throws {
    try Data(string.utf8).write(
        to: url,
        options: .atomic
    )
}

private func runCampaign(
    baselineRoot: URL,
    candidateRoot: URL,
    outputRoot: URL,
    layer: Layer
) throws -> LayerManifest {
    let campaignDirectory =
        outputRoot.appendingPathComponent(
            layer.name,
            isDirectory: true
        )
    let campaignExecutable =
        baselineRoot
            .appendingPathComponent(
                ".build/release"
            )
            .appendingPathComponent(
                "whitethroated-benchmark-campaign"
            )

    print(
        "running paired \(layer.name) campaign"
    )

    _ = try process(
        executable:
            campaignExecutable.path,
        arguments: [],
        currentDirectory: baselineRoot,
        environment: [
            "WHITETHROATED_CAMPAIGN_ROOT":
                baselineRoot.path,
            "WHITETHROATED_CAMPAIGN_PROFILE":
                "response-stream",
            "WHITETHROATED_CAMPAIGN_SERVER":
                layer.serverProduct,
            "WHITETHROATED_CAMPAIGN_AB_PEER_ROOT":
                candidateRoot.path,
            "WHITETHROATED_CAMPAIGN_OUTPUT":
                campaignDirectory.path,
        ]
    )

    let comparator =
        baselineRoot
            .appendingPathComponent(
                ".build/release"
            )
            .appendingPathComponent(
                "whitethroated-benchmark-ab-compare"
            )
    let baselineCampaign =
        campaignDirectory
            .appendingPathComponent(
                "baseline",
                isDirectory: true
            )
    let candidateCampaign =
        campaignDirectory
            .appendingPathComponent(
                "candidate",
                isDirectory: true
            )
    let comparison =
        outputRoot.appendingPathComponent(
            layer.name
            + "-comparison.json"
        )

    let report = try process(
        executable: comparator.path,
        arguments: [
            baselineCampaign.path,
            candidateCampaign.path,
        ],
        currentDirectory: baselineRoot,
        captureOutput: true
    )

    try write(
        report,
        to: comparison
    )

    return LayerManifest(
        name: layer.name,
        serverProduct:
            layer.serverProduct,
        campaignDirectory:
            campaignDirectory.path,
        comparisonFile:
            comparison.path
    )
}

private func removeWorktree(
    _ path: URL,
    repository: URL
) {
    _ = try? git(
        [
            "worktree",
            "remove",
            "--force",
            path.path,
        ],
        repository: repository
    )
}

private var failureOutput: URL?

do {
    let arguments =
        Array(
            CommandLine.arguments
                .dropFirst()
        )

    guard arguments.count == 3 else {
        throw DriverError.invalidArguments
    }

    let repository =
        try repositoryRoot()
    let baselineHead =
        try resolveCommit(
            arguments[0],
            repository: repository
        )
    let candidateHead =
        try resolveCommit(
            arguments[1],
            repository: repository
        )

    guard baselineHead != candidateHead else {
        throw DriverError.invalidArguments
    }

    let outputRoot =
        try requireFreshAbsoluteOutput(
            arguments[2],
            repository: repository
        )
    failureOutput = outputRoot

    try FileManager.default
        .createDirectory(
            at: outputRoot,
            withIntermediateDirectories: true
        )

    let worktreeRoot =
        FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                "whitethroated-response-stream-ab-"
                + UUID().uuidString,
                isDirectory: true
            )
    let baselineRoot =
        worktreeRoot
            .appendingPathComponent(
                "baseline",
                isDirectory: true
            )
    let candidateRoot =
        worktreeRoot
            .appendingPathComponent(
                "candidate",
                isDirectory: true
            )

    try FileManager.default
        .createDirectory(
            at: worktreeRoot,
            withIntermediateDirectories: true
        )

    var baselineAdded = false
    var candidateAdded = false

    defer {
        if candidateAdded {
            removeWorktree(
                candidateRoot,
                repository: repository
            )
        }
        if baselineAdded {
            removeWorktree(
                baselineRoot,
                repository: repository
            )
        }
        try? FileManager.default
            .removeItem(at: worktreeRoot)
    }

    try git(
        [
            "worktree",
            "add",
            "--detach",
            baselineRoot.path,
            baselineHead,
        ],
        repository: repository
    )
    baselineAdded = true

    try git(
        [
            "worktree",
            "add",
            "--detach",
            candidateRoot.path,
            candidateHead,
        ],
        repository: repository
    )
    candidateAdded = true

    let baselineProducts = [
        "whitethroated-benchmark-server",
        "whitethroated-runtime-benchmark-server",
        "raw-nio-benchmark-server",
        "whitethroated-benchmark-client",
        "whitethroated-benchmark-campaign",
        "whitethroated-benchmark-ab-compare",
    ]

    let candidateProducts = [
        "whitethroated-benchmark-server",
        "whitethroated-runtime-benchmark-server",
        "raw-nio-benchmark-server",
    ]

    try build(
        products: baselineProducts,
        root: baselineRoot
    )
    try build(
        products: candidateProducts,
        root: candidateRoot
    )

    try waitForBuildLoadToSettle()

    var layerManifests: [LayerManifest] = []

    for layer in layers {
        layerManifests.append(
            try runCampaign(
                baselineRoot: baselineRoot,
                candidateRoot: candidateRoot,
                outputRoot: outputRoot,
                layer: layer
            )
        )
    }

    let swiftVersion = try process(
        executable: "/usr/bin/env",
        arguments: [
            "swift",
            "--version",
        ],
        captureOutput: true
    ).trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let host = try process(
        executable: "/usr/bin/uname",
        arguments: ["-a"],
        captureOutput: true
    ).trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    let manifest = DriverManifest(
        schemaVersion: 1,
        baselineHead: baselineHead,
        candidateHead: candidateHead,
        repositoryRoot:
            repository.path,
        swiftVersion: swiftVersion,
        host: host,
        generatedAt:
            ISO8601DateFormatter()
                .string(from: Date()),
        layers: layerManifests
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted,
        .sortedKeys,
    ]
    let manifestURL =
        outputRoot.appendingPathComponent(
            "driver-manifest.json"
        )

    try encoder.encode(manifest).write(
        to: manifestURL,
        options: .atomic
    )

    try write(
        "Complete response-stream A/B driver run\n",
        to: outputRoot
            .appendingPathComponent(
                "DRIVER_COMPLETE.txt"
            )
    )

    print(
        "response-stream A/B campaign complete: "
        + outputRoot.path
    )
} catch {
    if let failureOutput {
        try? FileManager.default
            .createDirectory(
                at: failureOutput,
                withIntermediateDirectories: true
            )
        try? write(
            "\(error)\n",
            to: failureOutput
                .appendingPathComponent(
                    "DRIVER_ABORTED.txt"
                )
        )
    }

    FileHandle.standardError.write(
        Data(
            (
                "Response-stream A/B driver stopped: "
                + "\(error)\n"
            ).utf8
        )
    )
    exit(1)
}
