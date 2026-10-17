import BenchmarkResults
import Foundation

// stdout is machine-readable JSON; invalid/missing inputs fail the process.
// Usage: whitethroated-benchmark-merge <expected-shards> <file>...
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let paths = Array(arguments.dropFirst())
    guard let count = arguments.first.flatMap(Int.init), count > 0,
          paths.count == count,
          Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).count == paths.count else {
        throw BenchmarkMergeError.invalidSample
    }
    let samples = try paths.map {
        try JSONDecoder().decode(BenchmarkSample.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
    }
    let summary = try BenchmarkSummary(samples: samples)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(summary))
    print("")
} catch {
    FileHandle.standardError.write(Data("Cannot merge benchmark shards: \(error)\nUsage: whitethroated-benchmark-merge <expected-shards> <file>...\n".utf8))
    exit(1)
}
