import XCTest
@testable import BenchmarkResults

final class CampaignSupportTests: XCTestCase {
    func testConfigurationKeepsFullMatrixAndExplicitSmoke() throws {
        let config = try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/new"], currentDirectory: "/project")
        XCTAssertEqual(config.profile, .rest)
        XCTAssertEqual(config.rounds, 5)
        XCTAssertEqual(config.concurrencies, [64, 256, 512])
        XCTAssertEqual(config.shards, 8)
        XCTAssertEqual(config.serverLoops, 8)
        XCTAssertEqual(
            config.requestsPerShard * config.shards,
            1_000_000
        )

        let stream = try CampaignConfiguration(
            environment: [
                "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/stream",
                "WHITETHROATED_CAMPAIGN_PROFILE": "response-stream",
            ],
            currentDirectory: "/project"
        )
        XCTAssertEqual(stream.profile, .responseStream)
        XCTAssertEqual(stream.rounds, 3)
        XCTAssertEqual(stream.concurrencies, [64, 512])
        XCTAssertEqual(stream.shards, 4)
        XCTAssertEqual(stream.serverLoops, 2)
        XCTAssertNil(stream.abPeerRoot)
        XCTAssertEqual(
            stream.requestsPerShard * stream.shards,
            500_000
        )

        let paired = try CampaignConfiguration(
            environment: [
                "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/paired",
                "WHITETHROATED_CAMPAIGN_PROFILE": "response-stream",
                "WHITETHROATED_CAMPAIGN_AB_PEER_ROOT": "/candidate",
            ],
            currentDirectory: "/project"
        )
        XCTAssertEqual(
            paired.abPeerRoot,
            "/candidate"
        )

        let pairedSmokeSameRoot = try CampaignConfiguration(
            environment: [
                "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/paired-smoke",
                "WHITETHROATED_CAMPAIGN_PROFILE": "response-stream",
                "WHITETHROATED_CAMPAIGN_SMOKE": "1",
                "WHITETHROATED_CAMPAIGN_AB_PEER_ROOT": "/project",
            ],
            currentDirectory: "/project"
        )
        XCTAssertEqual(
            pairedSmokeSameRoot.abPeerRoot,
            "/project"
        )

        XCTAssertThrowsError(
            try CampaignConfiguration(
                environment: [
                    "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/paired-rest",
                    "WHITETHROATED_CAMPAIGN_AB_PEER_ROOT": "/candidate",
                ],
                currentDirectory: "/project"
            )
        )
        XCTAssertThrowsError(
            try CampaignConfiguration(
                environment: [
                    "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/paired-relative",
                    "WHITETHROATED_CAMPAIGN_PROFILE": "response-stream",
                    "WHITETHROATED_CAMPAIGN_AB_PEER_ROOT": "candidate",
                ],
                currentDirectory: "/project"
            )
        )
        XCTAssertThrowsError(
            try CampaignConfiguration(
                environment: [
                    "WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/paired-same",
                    "WHITETHROATED_CAMPAIGN_PROFILE": "response-stream",
                    "WHITETHROATED_CAMPAIGN_AB_PEER_ROOT": "/project",
                ],
                currentDirectory: "/project"
            )
        )

        let smoke = try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/smoke", "WHITETHROATED_CAMPAIGN_SMOKE": "1"], currentDirectory: "/project")
        XCTAssertEqual(smoke.rounds, 1)
        XCTAssertEqual(smoke.concurrencies, [64])
        XCTAssertThrowsError(try CampaignConfiguration(environment: [:], currentDirectory: "/project"))
        XCTAssertThrowsError(try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "relative"], currentDirectory: "/project"))
        for (key, value) in [
            ("WHITETHROATED_CAMPAIGN_SERVER", "unknown"),
            ("WHITETHROATED_CAMPAIGN_PORT", "65535"),
            ("WHITETHROATED_CAMPAIGN_SMOKE", "true"),
            ("WHITETHROATED_CAMPAIGN_PROFILE", "unknown"),
        ] {
            XCTAssertThrowsError(try CampaignConfiguration(environment: ["WHITETHROATED_CAMPAIGN_OUTPUT": "/tmp/new", key: value], currentDirectory: "/project"))
        }
    }

    func testResponseStreamABOrderAlternatesByRound() {
        XCTAssertEqual(
            responseStreamABOrder(round: 1),
            [.baseline, .candidate]
        )
        XCTAssertEqual(
            responseStreamABOrder(round: 2),
            [.candidate, .baseline]
        )
        XCTAssertEqual(
            responseStreamABOrder(round: 3),
            [.baseline, .candidate]
        )
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
