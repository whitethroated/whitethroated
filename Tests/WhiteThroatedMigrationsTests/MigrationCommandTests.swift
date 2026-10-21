import WhiteThroatedMigrations
import XCTest

final class MigrationCommandTests: XCTestCase {
    func testUsesEnvironmentDatabaseURL() throws {
        let command =
            try MigrationCommand.parse(
                arguments: [],
                environment: [
                    "DATABASE_URL":
                        "postgres://user:pass@localhost/db",
                ]
            )

        XCTAssertEqual(command.mode, .apply)
        XCTAssertEqual(
            command.databaseURL,
            "postgres://user:pass@localhost/db"
        )
        XCTAssertEqual(
            command.migrationsDirectory,
            "Migrations"
        )
    }

    func testExplicitArgumentsOverrideEnvironment()
        throws
    {
        let command =
            try MigrationCommand.parse(
                arguments: [
                    "--database-url",
                    "postgres://override/db",
                    "--migrations",
                    "db/migrations",
                    "--table",
                    "schema_migrations",
                    "--dry-run",
                ],
                environment: [
                    "DATABASE_URL":
                        "postgres://env/db",
                ]
            )

        XCTAssertEqual(command.mode, .dryRun)
        XCTAssertEqual(
            command.databaseURL,
            "postgres://override/db"
        )
        XCTAssertEqual(
            command.migrationsDirectory,
            "db/migrations"
        )
        XCTAssertEqual(
            command.tableName,
            "schema_migrations"
        )
    }

    func testEqualsFormsAndStatus() throws {
        let command =
            try MigrationCommand.parse(
                arguments: [
                    "--database-url=postgres://db",
                    "--migrations=sql",
                    "--table=history",
                    "--status",
                ],
                environment: [:]
            )

        XCTAssertEqual(command.mode, .status)
        XCTAssertEqual(
            command.databaseURL,
            "postgres://db"
        )
    }

    func testHelpDoesNotRequireDatabaseURL() throws {
        let command =
            try MigrationCommand.parse(
                arguments: ["--help"],
                environment: [:]
            )

        XCTAssertEqual(command.mode, .help)
        XCTAssertNil(command.databaseURL)
    }

    func testMissingDatabaseURLFails() {
        XCTAssertThrowsError(
            try MigrationCommand.parse(
                arguments: [],
                environment: [:]
            )
        ) {
            XCTAssertEqual(
                $0 as? MigrationCommandError,
                .missingDatabaseURL
            )
        }
    }

    func testConflictingModesFail() {
        XCTAssertThrowsError(
            try MigrationCommand.parse(
                arguments: [
                    "--status",
                    "--dry-run",
                    "--database-url",
                    "postgres://db",
                ],
                environment: [:]
            )
        ) {
            XCTAssertEqual(
                $0 as? MigrationCommandError,
                .conflictingModes
            )
        }
    }

    func testMissingAndUnknownArgumentsFail() {
        XCTAssertThrowsError(
            try MigrationCommand.parse(
                arguments: [
                    "--database-url",
                ],
                environment: [:]
            )
        ) {
            XCTAssertEqual(
                $0 as? MigrationCommandError,
                .missingValue("--database-url")
            )
        }

        XCTAssertThrowsError(
            try MigrationCommand.parse(
                arguments: [
                    "--unknown",
                ],
                environment: [
                    "DATABASE_URL":
                        "postgres://db",
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? MigrationCommandError,
                .unexpectedArgument("--unknown")
            )
        }
    }
}
