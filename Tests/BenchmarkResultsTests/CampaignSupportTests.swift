import XCTest
@testable import BenchmarkResults

final class CampaignSupportTests: XCTestCase {
    func testConfigurationKeepsFullMatrixAndExplicitSmoke() throws {
        let config = try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/new"], currentDirectory: "/project")
        XCTAssertEqual(config.rounds, 5)
        XCTAssertEqual(config.concurrencies, [64, 256, 512])
        XCTAssertEqual(config.requestsPerShard * 8, 1_000_000)
        let smoke = try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/smoke", "WHITETHROATED_CAMPAIGN_SMOKE": "1"], currentDirectory: "/project")
        XCTAssertEqual(smoke.rounds, 1)
        XCTAssertEqual(smoke.concurrencies, [64])
        let customHTTP1 = try CampaignConfiguration(
            environment: [
                "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/custom",
                "WHITETHROATED_CAMPAIGN_SERVER": "custom-http1-benchmark-server"
            ],
            currentDirectory: "/project"
        )
        XCTAssertEqual(customHTTP1.serverProduct, "custom-http1-benchmark-server")
        let http1Experiment = try CampaignConfiguration(
            environment: [
                "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/http1",
                "WHITETHROATED_CAMPAIGN_SERVER": "custom-http1-benchmark-server",
                "WHITETHROATED_CAMPAIGN_HTTP1_EXPERIMENT": "1"
            ],
            currentDirectory: "/project"
        )
        XCTAssertTrue(http1Experiment.http1Experiment)
        XCTAssertThrowsError(
            try CampaignConfiguration(
                environment: [
                    "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/http1-framework",
                    "WHITETHROATED_CAMPAIGN_SERVER": "whitethroated-benchmark-server",
                    "WHITETHROATED_CAMPAIGN_HTTP1_EXPERIMENT": "1"
                ],
                currentDirectory: "/project"
            )
        )
        XCTAssertThrowsError(try CampaignConfiguration(environment: [:], currentDirectory: "/project"))
        XCTAssertThrowsError(try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "relative"], currentDirectory: "/project"))
        for (key, value) in [("WHITETHROATED_CAMPAIGN_SERVER", "unknown"), ("WHITETHROATED_CAMPAIGN_PORT", "65535"), ("WHITETHROATED_CAMPAIGN_SMOKE", "true"), ("WHITETHROATED_CAMPAIGN_HTTP1_EXPERIMENT", "true")] {
            XCTAssertThrowsError(try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/new", key: value], currentDirectory: "/project"))
        }
    }

    func testParsesMacAndLinuxCumulativeCPU() throws {
        let values = try WorkerObservation.parse(" 123 1024 1:02.34\n456 2048 2-03:04:05\n")
        XCTAssertEqual(values.map(\.pid), [123, 456])
        XCTAssertEqual(values.map(\.rssKiB), [1024, 2048])
        XCTAssertEqual(values[0].cpuSeconds, 62.34, accuracy: 0.000001)
        XCTAssertEqual(values[1].cpuSeconds, 183845)
        XCTAssertEqual(try WorkerObservation.cpuTime("120:00.01"), 7200.01, accuracy: 0.000001)
        for invalid in ["", "NaN", "00:NaN", "-1:00", "00:60", "1:60:00", "a:00", "1-2-00:00"] {
            XCTAssertThrowsError(try WorkerObservation.cpuTime(invalid), invalid)
        }
        XCTAssertThrowsError(try WorkerObservation.parse("12 -1 00:00"))
        XCTAssertThrowsError(try WorkerObservation.parse("missing-worker"))
    }

    func testResourcePeakUsesConcurrentSumAndCPUDeltas() throws {
        func point(_ time: UInt64, _ firstRSS: Int, _ secondRSS: Int, _ cpu: Double) -> ResourceObservation {
            ResourceObservation(uptimeNanoseconds: time, workers: [
                WorkerObservation(pid: 1, rssKiB: firstRSS, cpuSeconds: cpu),
                WorkerObservation(pid: 2, rssKiB: secondRSS, cpuSeconds: cpu)
            ])
        }
        let observations = [point(1, 100, 10, 3), point(500_000_001, 50, 60, 3.25), point(1_000_000_001, 20, 100, 3.5)]
        let result = try ResourceSummary(observations: observations, completed: 1000)
        XCTAssertEqual(result.sampledPeakAggregateRSSKiB, 120) // not 100 + 100
        XCTAssertEqual(result.cpuSeconds, 1)
        XCTAssertEqual(result.cpuPercent, 100)
        XCTAssertEqual(result.completedRequestsPerCPUSecond, 1000)
        XCTAssertThrowsError(try ResourceSummary(observations: [], completed: 1000))
        XCTAssertThrowsError(try ResourceSummary(observations: [observations[2], observations[0]], completed: 1000))
        XCTAssertThrowsError(try ResourceSummary(observations: [observations[0], point(2, 10, 10, 2)], completed: 1000))
        let replaced = ResourceObservation(uptimeNanoseconds: 2, workers: [WorkerObservation(pid: 3, rssKiB: 100, cpuSeconds: 3)])
        XCTAssertThrowsError(try ResourceSummary(observations: [observations[0], replaced], completed: 1000))
        let idle = try ResourceSummary(observations: [point(1, 10, 10, 0), point(2, 10, 10, 0)], completed: 1)
        XCTAssertNil(idle.completedRequestsPerCPUSecond)
        XCTAssertEqual(idle.cpuPercent, 0)
    }
}
