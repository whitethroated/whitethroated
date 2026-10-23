import BenchmarkResults
import XCTest

final class ResponseStreamABComparisonTests:
    XCTestCase
{
    func testPairedComparisonUsesRoundPairing() throws {
        let comparison =
            try PairedBenchmarkMetricComparison(
                baseline: [
                    100,
                    90,
                    110,
                ],
                candidate: [
                    110,
                    99,
                    121,
                ]
            )

        XCTAssertEqual(
            comparison.baselineMedian,
            100,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            comparison.candidateMedian,
            110,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            comparison
                .pairedMedianPercentChange,
            10,
            accuracy: 0.000_001
        )
    }

    func testPairedComparisonRejectsMismatchedSeries() {
        XCTAssertThrowsError(
            try PairedBenchmarkMetricComparison(
                baseline: [1, 2],
                candidate: [1]
            )
        ) {
            XCTAssertEqual(
                $0 as? BenchmarkComparisonError,
                .mismatchedSeriesLength
            )
        }
    }

    func testPairedComparisonRejectsZeroBaseline() {
        XCTAssertThrowsError(
            try PairedBenchmarkMetricComparison(
                baseline: [0],
                candidate: [1]
            )
        ) {
            XCTAssertEqual(
                $0 as? BenchmarkComparisonError,
                .zeroBaseline
            )
        }
    }
}
