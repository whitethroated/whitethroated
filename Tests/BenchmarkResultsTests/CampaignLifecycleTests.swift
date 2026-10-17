import Foundation
import XCTest
@testable import BenchmarkResults
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Opt-in subprocess tests; exercise actual signal handling and child cleanup.
final class CampaignLifecycleTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func requireIntegration() throws {
        guard ProcessInfo.processInfo.environment["WHITETHROATED_CAMPAIGN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set WHITETHROATED_CAMPAIGN_INTEGRATION=1 for campaign subprocess checks")
        }
    }

    private func launch(output: URL, port: Int) throws -> Process {
        let process = Process()
        process.executableURL = root.appendingPathComponent(".build/release/whitethroated-benchmark-campaign")
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("WHITETHROATED_") }.merging([
            "WHITETHROATED_CAMPAIGN_ROOT": root.path, "WHITETHROATED_CAMPAIGN_OUTPUT": output.path,
            "WHITETHROATED_CAMPAIGN_SMOKE": "1", "WHITETHROATED_CAMPAIGN_PORT": String(port)
        ]) { _, value in value }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func cleanup(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func waitForExit(_ process: Process) throws {
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        guard !process.isRunning else { throw CampaignError.invalid("Campaign did not exit after SIGTERM") }
        process.waitUntilExit()
    }

    func testExistingOutputIsPreserved() throws {
        try requireIntegration()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let marker = output.appendingPathComponent("marker.txt")
        try Data("preserve".utf8).write(to: marker)
        let process = try launch(output: output, port: 3470)
        defer { cleanup(process) }
        try waitForExit(process)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["marker.txt"])
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
    }

    func testSIGTERMCleansObservedWorker() throws {
        try requireIntegration()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let process = try launch(output: output, port: 3480)
        var workerPID: Int32?
        defer {
            cleanup(process)
            // Only this campaign's worker, obtained from its own observation.
            if let workerPID, kill(workerPID, 0) == 0 { _ = kill(workerPID, SIGKILL) }
            try? FileManager.default.removeItem(at: output)
        }
        let idle = output.appendingPathComponent("r1-1x8-idle.json")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: idle.path) && process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let observation = try JSONDecoder().decode(ResourceObservation.self, from: Data(contentsOf: idle))
        workerPID = try XCTUnwrap(observation.workers.first?.pid)
        XCTAssertTrue(process.isRunning)
        _ = kill(process.processIdentifier, SIGTERM)
        try waitForExit(process)
        XCTAssertEqual(process.terminationStatus, 1, "Expected handled interruption, reason \(process.terminationReason.rawValue)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("ABORTED.txt").path))
        let alive = kill(try XCTUnwrap(workerPID), 0)
        XCTAssertNotEqual(alive, 0, "Observed campaign worker survived SIGTERM")
        if alive != 0 { workerPID = nil }
    }

    func testOccupiedPortAbortsBeforeLaunchingWorker() throws {
        try requireIntegration()
        #if os(macOS)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw CampaignError.invalid("Test socket unavailable") }
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(3490).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(macOS)
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard result == 0, listen(descriptor, 1) == 0 else {
            throw CampaignError.invalid("Lifecycle test port 3490 must be unused")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = try launch(output: output, port: 3490)
        defer { cleanup(process) }
        try waitForExit(process)
        XCTAssertEqual(process.terminationStatus, 1)
        let error = try String(contentsOf: output.appendingPathComponent("ABORTED.txt"), encoding: .utf8)
        XCTAssertTrue(error.contains("port 3490 is unavailable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("r1-1x8-worker-0.log").path))
        XCTAssertNotEqual(fcntl(descriptor, F_GETFD), -1, "Original listening socket must remain open")
    }
}
