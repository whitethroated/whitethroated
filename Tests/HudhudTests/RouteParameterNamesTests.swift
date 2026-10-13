import XCTest
@testable import Hudhud

final class RouteParameterNamesTests: XCTestCase {
    func testInlineStorageForFirstTwoNames() {
        var names = RouteParameterNames.none

        names.append("id")

        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names[0], "id")

        names.append("post")

        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names[0], "id")
        XCTAssertEqual(names[1], "post")
    }

    func testThirdNamePromotesToArrayStorage() {
        var names = RouteParameterNames.none

        names.append("one")
        names.append("two")
        names.append("three")

        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(names[0], "one")
        XCTAssertEqual(names[1], "two")
        XCTAssertEqual(names[2], "three")
    }

    func testEmptyNamesReportsEmpty() {
        let names = RouteParameterNames.none

        XCTAssertTrue(names.isEmpty)
        XCTAssertEqual(names.count, 0)
    }
}
