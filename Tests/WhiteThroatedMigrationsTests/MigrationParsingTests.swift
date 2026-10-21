import Foundation
import WhiteThroatedMigrations
import XCTest

final class MigrationParsingTests: XCTestCase {
    func testSplitterHandlesStringsAndSemicolons() throws {
        XCTAssertEqual(
            try SQLStatementSplitter.split(
                "SELECT 1; SELECT ';'; SELECT \"a;b\";"
            ),
            [
                "SELECT 1",
                "SELECT ';'",
                "SELECT \"a;b\"",
            ]
        )
    }

    func testSplitterHandlesDollarQuotedBodies() throws {
        let sql =
            """
            CREATE FUNCTION f() RETURNS void AS $$
            BEGIN
                PERFORM ';';
            END;
            $$ LANGUAGE plpgsql;
            SELECT 1;
            """

        XCTAssertEqual(
            try SQLStatementSplitter.split(sql)
                .count,
            2
        )
    }

    func testSplitterTreatsDollarInIdentifiersAsIdentifier() throws {
        XCTAssertEqual(
            try SQLStatementSplitter.split(
                "CREATE TABLE a$b$c (x int); SELECT 2;"
            ),
            [
                "CREATE TABLE a$b$c (x int)",
                "SELECT 2",
            ]
        )
    }

    func testSplitterStartsWithDollarQuoteAfterNumericLiteral() throws {
        XCTAssertEqual(
            try SQLStatementSplitter.split(
                "SELECT 1$$body;$$; SELECT 2;"
            ),
            [
                "SELECT 1$$body;$$",
                "SELECT 2",
            ]
        )
    }

    func testSplitterDropsCommentsAndKeepsTokenSeparation() throws {
        XCTAssertEqual(
            try SQLStatementSplitter.split(
                """
                SELECT 1; -- trailing ;
                SELECT foo/* ; */bar;
                /*
                nested /* ; */
                */
                SELECT 3;
                """
            ),
            [
                "SELECT 1",
                "SELECT foo bar",
                "SELECT 3",
            ]
        )
    }

    func testSplitterHandlesEscapedQuotes() throws {
        XCTAssertEqual(
            try SQLStatementSplitter.split(
                "SELECT 'it''s; fine'; SELECT 2;"
            ),
            [
                "SELECT 'it''s; fine'",
                "SELECT 2",
            ]
        )
    }

    func testSplitterTreatsBackslashAsLiteralInStandardStrings() throws {
        XCTAssertEqual(
            try SQLStatementSplitter.split(
                #"SELECT 'C:\'; SELECT 2;"#
            ),
            [
                #"SELECT 'C:\'"#,
                "SELECT 2",
            ]
        )
    }

    func testSplitterHandlesEscapeStringBackslashes() throws {
        XCTAssertEqual(
            try SQLStatementSplitter.split(
                #"SELECT E'it\'s; fine'; SELECT 2;"#
            ),
            [
                #"SELECT E'it\'s; fine'"#,
                "SELECT 2",
            ]
        )
    }

    func testSplitterRejectsUnterminatedConstructs() {
        XCTAssertThrowsError(
            try SQLStatementSplitter.split(
                "SELECT 1; /* unfinished"
            )
        ) {
            XCTAssertEqual(
                $0 as? SQLStatementSplitterError,
                .unterminatedBlockComment
            )
        }

        XCTAssertThrowsError(
            try SQLStatementSplitter.split(
                "SELECT 'unfinished"
            )
        ) {
            XCTAssertEqual(
                $0 as? SQLStatementSplitterError,
                .unterminatedString
            )
        }

        XCTAssertThrowsError(
            try SQLStatementSplitter.split(
                "SELECT $$unfinished"
            )
        ) {
            XCTAssertEqual(
                $0 as? SQLStatementSplitterError,
                .unterminatedDollarQuote
            )
        }
    }

    func testChecksumDistinguishesStatementBoundaries() {
        XCTAssertNotEqual(
            Migration.checksum(
                of: ["a\0b"]
            ),
            Migration.checksum(
                of: ["a", "b"]
            )
        )
    }

    func testChecksumIsStableAndSensitiveToStatements() {
        let first =
            Migration(
                id: "001",
                statements: ["SELECT 1"]
            )
        let same =
            Migration(
                id: "001",
                statements: ["SELECT 1"]
            )
        let changed =
            Migration(
                id: "001",
                statements: ["SELECT 2"]
            )

        XCTAssertEqual(
            first.checksum,
            same.checksum
        )
        XCTAssertNotEqual(
            first.checksum,
            changed.checksum
        )
        XCTAssertEqual(
            first.checksum.count,
            64
        )
        XCTAssertTrue(
            first.checksum.allSatisfy {
                "0123456789abcdef"
                    .contains($0)
            }
        )
    }

    func testFileLoaderSortsAndUsesFilenameAsID()
        throws
    {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "wt-migrations-\(UUID())",
                    isDirectory: true
                )

        try FileManager.default
            .createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        defer {
            try? FileManager.default
                .removeItem(
                    at: directory
                )
        }

        try Data("SELECT 2;".utf8)
            .write(
                to: directory
                    .appendingPathComponent(
                        "002_second.sql"
                    )
            )
        try Data("SELECT 1;".utf8)
            .write(
                to: directory
                    .appendingPathComponent(
                        "001_first.sql"
                    )
            )
        try Data("ignored".utf8)
            .write(
                to: directory
                    .appendingPathComponent(
                        "README.txt"
                    )
            )

        let migrations =
            try MigrationFileLoader.load(
                directory: directory.path
            )

        XCTAssertEqual(
            migrations.map(\.id),
            [
                "001_first",
                "002_second",
            ]
        )
        XCTAssertEqual(
            migrations.map(\.statements),
            [
                ["SELECT 1"],
                ["SELECT 2"],
            ]
        )
    }

    func testFileLoaderRejectsInvalidUTF8()
        throws
    {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "wt-migrations-\(UUID())",
                    isDirectory: true
                )

        try FileManager.default
            .createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        defer {
            try? FileManager.default
                .removeItem(
                    at: directory
                )
        }

        try Data([0xFF])
            .write(
                to: directory
                    .appendingPathComponent(
                        "001_bad.sql"
                    )
            )

        XCTAssertThrowsError(
            try MigrationFileLoader.load(
                directory: directory.path
            )
        ) {
            guard
                let error =
                    $0 as? MigrationFileError,
                case .invalidUTF8 = error
            else {
                return XCTFail(
                    "Unexpected error: \($0)"
                )
            }
        }
    }

    func testFileLoaderRejectsUnterminatedSQL()
        throws
    {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "wt-migrations-\(UUID())",
                    isDirectory: true
                )

        try FileManager.default
            .createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        defer {
            try? FileManager.default
                .removeItem(
                    at: directory
                )
        }

        try Data(
            "SELECT 1; /* unfinished".utf8
        )
        .write(
            to: directory
                .appendingPathComponent(
                    "001_bad.sql"
                )
        )

        XCTAssertThrowsError(
            try MigrationFileLoader.load(
                directory: directory.path
            )
        ) {
            guard
                let error =
                    $0 as? MigrationFileError,
                case .invalidSQL = error
            else {
                return XCTFail(
                    "Unexpected error: \($0)"
                )
            }
        }
    }
}
