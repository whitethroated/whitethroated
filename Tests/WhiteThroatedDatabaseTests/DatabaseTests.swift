import Foundation
import WhiteThroatedDatabase
import WhiteThroatedDatabaseTestSupport
import XCTest

final class DatabaseTests: XCTestCase {
    func testValueConversionsRoundTrip() throws {
        XCTAssertEqual(
            try Bool.decodeDatabaseValue(
                Bool(true).databaseValue
            ),
            true
        )
        XCTAssertEqual(
            try Int.decodeDatabaseValue(
                Int(42).databaseValue
            ),
            42
        )
        XCTAssertEqual(
            try Int64.decodeDatabaseValue(
                Int64.max.databaseValue
            ),
            Int64.max
        )
        XCTAssertEqual(
            try Double.decodeDatabaseValue(
                Double(1.5).databaseValue
            ),
            1.5
        )
        XCTAssertEqual(
            try String.decodeDatabaseValue(
                String("hello").databaseValue
            ),
            "hello"
        )

        let uuid = UUID()
        XCTAssertEqual(
            try UUID.decodeDatabaseValue(
                uuid.databaseValue
            ),
            uuid
        )

        let bytes: [UInt8] = [0, 1, 255]
        XCTAssertEqual(
            try [UInt8].decodeDatabaseValue(
                bytes.databaseValue
            ),
            bytes
        )
    }

    func testValueMismatchAndRangeErrors() {
        XCTAssertThrowsError(
            try String.decodeDatabaseValue(
                .int(1)
            )
        ) {
            XCTAssertEqual(
                $0 as? DatabaseValueError,
                .typeMismatch(
                    expected: "string",
                    actual: "int"
                )
            )
        }

        XCTAssertThrowsError(
            try Int.decodeDatabaseValue(
                .double(1)
            )
        ) {
            XCTAssertEqual(
                $0 as? DatabaseValueError,
                .typeMismatch(
                    expected: "int",
                    actual: "double"
                )
            )
        }
    }

    func testRowDecodingAndNulls() throws {
        let row: DatabaseRow = [
            "id": .int(7),
            "name": .string("Ada"),
            "nickname": .null,
        ]

        XCTAssertEqual(
            try row.decode("id", as: Int.self),
            7
        )
        XCTAssertEqual(
            try row.decode("name", as: String.self),
            "Ada"
        )
        XCTAssertNil(
            try row.decodeIfPresent(
                "nickname",
                as: String.self
            )
        )
        XCTAssertThrowsError(
            try row.decode("missing", as: String.self)
        ) {
            XCTAssertEqual(
                $0 as? DatabaseRowError,
                .missingColumn("missing")
            )
        }
    }

    func testIdentifierQuotingEscapesQuotes() {
        XCTAssertEqual(
            DatabaseIdentifier.quote("users"),
            "\"users\""
        )
        XCTAssertEqual(
            DatabaseIdentifier.quote(
                "odd\"name"
            ),
            "\"odd\"\"name\""
        )
        XCTAssertEqual(
            DatabaseIdentifier.quote(
                ["a", "b"]
            ),
            "\"a\", \"b\""
        )
    }

    func testConnectionExecuteConvenienceUsesBindings() async throws {
        let database =
            ScriptedDatabase {
                query in

                XCTAssertEqual(
                    query.sql,
                    "SELECT $1"
                )
                XCTAssertEqual(
                    query.bindings,
                    [.int(1)]
                )
                return .empty
            }

        _ = try await database.execute(
            "SELECT $1",
            [.int(1)]
        )
    }

    func testTransactionCommitsAndRecordsBoundary() async throws {
        let database =
            ScriptedDatabase { _ in
                .empty
            }

        let value =
            try await database.withTransaction {
                transaction in

                _ = try await transaction.execute(
                    "SELECT 1"
                )
                return 9
            }

        XCTAssertEqual(value, 9)
        XCTAssertEqual(
            database.recordedQueries.map(\.sql),
            [
                "BEGIN",
                "SELECT 1",
                "COMMIT",
            ]
        )
    }

    func testTransactionRollsBackAndRethrows() async throws {
        struct TestError: Error {}

        let database =
            ScriptedDatabase { _ in
                .empty
            }

        do {
            try await database.withTransaction {
                _ in

                throw TestError()
            }
            XCTFail(
                "Expected transaction to throw"
            )
        } catch {
            XCTAssertTrue(error is TestError)
        }

        XCTAssertEqual(
            database.recordedQueries.map(\.sql),
            [
                "BEGIN",
                "ROLLBACK",
            ]
        )
    }

    func testShutdownIsIdempotent() async throws {
        let database =
            ScriptedDatabase { _ in
                .empty
            }

        try await database.shutdown()
        try await database.shutdown()

        XCTAssertTrue(database.isShutdown)
    }
}
