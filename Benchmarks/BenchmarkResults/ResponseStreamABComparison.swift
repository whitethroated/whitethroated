import Foundation

public enum BenchmarkComparisonError:
    Error,
    Sendable,
    Equatable
{
    case emptySeries
    case mismatchedSeriesLength
    case nonFiniteValue
    case zeroBaseline
}

public struct PairedBenchmarkMetricComparison:
    Codable,
    Sendable,
    Equatable
{
    public let baselineMedian: Double
    public let candidateMedian: Double
    public let pairedMedianPercentChange: Double

    public init(
        baseline: [Double],
        candidate: [Double]
    ) throws {
        guard
            !baseline.isEmpty,
            !candidate.isEmpty
        else {
            throw BenchmarkComparisonError.emptySeries
        }

        guard baseline.count == candidate.count else {
            throw BenchmarkComparisonError
                .mismatchedSeriesLength
        }

        guard
            baseline.allSatisfy(\.isFinite),
            candidate.allSatisfy(\.isFinite)
        else {
            throw BenchmarkComparisonError.nonFiniteValue
        }

        guard baseline.allSatisfy({ $0 != 0 }) else {
            throw BenchmarkComparisonError.zeroBaseline
        }

        baselineMedian = Self.median(baseline)
        candidateMedian = Self.median(candidate)

        pairedMedianPercentChange = Self.median(
            zip(baseline, candidate).map {
                pair in

                let (base, value) = pair

                return (value / base - 1) * 100
            }
        )
    }

    private static func median(
        _ values: [Double]
    ) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2

        guard sorted.count.isMultiple(of: 2) else {
            return sorted[middle]
        }

        return (
            sorted[middle - 1]
                + sorted[middle]
        ) / 2
    }
}
