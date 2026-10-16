import XCTest
@testable import WhiteThroated

final class RouteParameterRangesTests: XCTestCase {
    func testInlineStorageForFirstTwoRanges() {
        var ranges = RouteParameterRanges.none

        ranges.append(1..<2)

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], 1..<2)

        ranges.append(3..<5)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 1..<2)
        XCTAssertEqual(ranges[1], 3..<5)
    }

    func testDecodingHintsFollowInlineStorage() {
        var ranges = RouteParameterRanges.none

        ranges.append(
            1..<2,
            requiresDecoding: false
        )
        ranges.append(
            3..<8,
            requiresDecoding: true
        )

        XCTAssertFalse(
            ranges.requiresDecoding(at: 0)
        )
        XCTAssertTrue(
            ranges.requiresDecoding(at: 1)
        )

        ranges.removeLast()

        XCTAssertFalse(
            ranges.requiresDecoding(at: 0)
        )
    }

    func testThirdRangePromotesToManyStorage() {
        var ranges = RouteParameterRanges.none

        ranges.append(1..<2)
        ranges.append(3..<5)
        ranges.append(8..<13)

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[2], 8..<13)
    }

    func testBacktrackingDemotesStorage() {
        var ranges = RouteParameterRanges.none

        ranges.append(1..<2)
        ranges.append(3..<5)
        ranges.append(8..<13)

        ranges.removeLast()

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 1..<2)
        XCTAssertEqual(ranges[1], 3..<5)

        ranges.removeLast()

        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], 1..<2)

        ranges.removeLast()

        XCTAssertEqual(ranges.count, 0)
    }
}
