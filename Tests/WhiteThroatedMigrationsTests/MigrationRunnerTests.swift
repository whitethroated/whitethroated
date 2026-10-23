import WhiteThroatedDatabase
import WhiteThroatedDatabaseTestSupport
import WhiteThroatedMigrations
import XCTest

private actor MigrationStore {
    private var records:
        [String: String] = [:]

    func rows() -> [DatabaseRow] {
        records
            .sorted {
                $0.key < $1.key
            }
            .map {
                [
                    "id": .string($0.key),
                    "checksum":
                        .string($0.value),
                ]
            }
    }

    func record(
        id: String,
        checksum: String
    ) {
        records[id] = checksum
    }

    func snapshot() -> [String: String] {
        records
    }
}

private actor LockCounter {
    private var total = 0
    private var active = 0

    func enter() {
        total += 1
        active += 1
    }

    func exit() {
        active -= 1
    }

    func snapshot() -> (
        total: Int,
        active: Int
    ) {
        (total, active)
    }
}

private final class LockingDatabase:
    Database,
    DatabaseMigrationLocking,
    @unchecked Sendable
{
    let base: ScriptedDatabase
    let counter = LockCounter()

    init(base: ScriptedDatabase) {
        self.base = base
    }

    func execute(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult {
        try await base.execute(query)
    }

    func withConnection<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseConnection
        ) async throws -> T
    ) async throws -> T {
        try await base.withConnection(body)
    }

    func withTransaction<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseTransaction
        ) async throws -> T
    ) async throws -> T {
        try await base.withTransaction(body)
    }

    func shutdown() async throws {
        try await base.shutdown()
    }

    func withMigrationLock<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        await counter.enter()

        do {
            let value = try await body()
            await counter.exit()
            return value
        } catch {
            await counter.exit()
            throw error
        }
    }
}

final class MigrationRunnerTests: XCTestCase {
    func testApplyThenStatusAndSkip() async throws {
        let store =
            MigrationStore()
        let database =
            makeDatabase(store: store)
        let runner = try MigrationRunner(
            database: database,
            clock: { 1_000 }
        )
        let migrations = [
            Migration(
                id: "001",
                statements: [
                    "CREATE TABLE users (id INT)"
                ]
            ),
            Migration(
                id: "002",
                statements: [
                    "INSERT INTO users VALUES (1)"
                ]
            ),
        ]

        let first =
            try await runner.migrate(migrations)

        XCTAssertEqual(
            first.applied,
            ["001", "002"]
        )
        XCTAssertEqual(first.skipped, [])
        XCTAssertFalse(first.dryRun)
        let storedAfterFirst =
            await store.snapshot()
        XCTAssertEqual(
            storedAfterFirst,
            [
                "001": migrations[0].checksum,
                "002": migrations[1].checksum,
            ]
        )

        let second =
            try await runner.migrate(migrations)
        XCTAssertEqual(second.applied, [])
        XCTAssertEqual(
            second.skipped,
            ["001", "002"]
        )

        let status =
            try await runner.status(migrations)
        XCTAssertEqual(
            status.applied,
            ["001", "002"]
        )
        XCTAssertEqual(status.pending, [])
    }

    func testDryRunDoesNotOpenTransaction()
        async throws
    {
        let store =
            MigrationStore()
        let database =
            makeDatabase(store: store)
        let runner = try MigrationRunner(
            database: database
        )
        let migrations = [
            Migration(
                id: "001",
                statements: ["SELECT 1"]
            )
        ]

        let report =
            try await runner.migrate(
                migrations,
                dryRun: true
            )

        XCTAssertEqual(
            report.applied,
            ["001"]
        )
        XCTAssertTrue(report.dryRun)
        let storedAfterDryRun =
            await store.snapshot()
        XCTAssertEqual(
            storedAfterDryRun,
            [:]
        )
        XCTAssertFalse(
            database.recordedQueries.contains {
                $0.sql == "BEGIN"
            }
        )
    }

    func testChecksumMismatchIsRejected()
        async throws
    {
        let store =
            MigrationStore()
        await store.record(
            id: "001",
            checksum: "wrong"
        )
        let database =
            makeDatabase(store: store)
        let runner = try MigrationRunner(
            database: database
        )
        let migration =
            Migration(
                id: "001",
                statements: ["SELECT 1"]
            )

        do {
            _ = try await runner.migrate(
                [migration]
            )
            XCTFail(
                "Expected checksum mismatch"
            )
        } catch {
            XCTAssertEqual(
                error as? MigrationError,
                .checksumMismatch(
                    id: "001",
                    recorded: "wrong",
                    computed: migration.checksum
                )
            )
        }
    }

    func testAppliedMigrationMissingFromInputIsRejected()
        async throws
    {
        let store =
            MigrationStore()
        await store.record(
            id: "999",
            checksum: "abc"
        )
        let database =
            makeDatabase(store: store)
        let runner = try MigrationRunner(
            database: database
        )

        do {
            _ = try await runner.migrate([])
            XCTFail(
                "Expected missing migration error"
            )
        } catch {
            XCTAssertEqual(
                error as? MigrationError,
                .appliedMigrationNotProvided(
                    "999"
                )
            )
        }
    }

    func testDuplicateIDsAreRejectedBeforeDatabaseWork()
        async throws
    {
        let store =
            MigrationStore()
        let database =
            makeDatabase(store: store)
        let runner = try MigrationRunner(
            database: database
        )
        let migration =
            Migration(
                id: "001",
                statements: []
            )

        do {
            _ = try await runner.migrate([
                migration,
                migration,
            ])
            XCTFail(
                "Expected duplicate migration error"
            )
        } catch {
            XCTAssertEqual(
                error as? MigrationError,
                .duplicateID("001")
            )
        }

        XCTAssertTrue(
            database.recordedQueries.isEmpty
        )
    }

    func testStatementFailureRollsBack()
        async throws
    {
        let store =
            MigrationStore()
        let database =
            makeDatabase(store: store)
        let runner = try MigrationRunner(
            database: database
        )

        do {
            _ = try await runner.migrate([
                Migration(
                    id: "001",
                    statements: ["FAIL"]
                )
            ])
            XCTFail(
                "Expected statement failure"
            )
        } catch {
            XCTAssertTrue(
                error is TestDatabaseError
            )
        }

        let storedAfterFailure =
            await store.snapshot()
        XCTAssertEqual(
            storedAfterFailure,
            [:]
        )
        XCTAssertTrue(
            database.recordedQueries.contains {
                $0.sql == "ROLLBACK"
            }
        )
    }

    func testRunnerUsesMigrationLockWhenAvailable()
        async throws
    {
        let store =
            MigrationStore()
        let locking =
            LockingDatabase(
                base: makeDatabase(
                    store: store
                )
            )
        let runner = try MigrationRunner(
            database: locking
        )

        _ = try await runner.migrate([
            Migration(
                id: "001",
                statements: ["SELECT 1"]
            )
        ])

        let snapshot =
            await locking.counter.snapshot()
        XCTAssertEqual(snapshot.total, 1)
        XCTAssertEqual(snapshot.active, 0)
    }

    func testInvalidTrackingTableNameThrows() {
        let database =
            makeDatabase(
                store: MigrationStore()
            )

        XCTAssertThrowsError(
            try MigrationRunner(
                database: database,
                tableName: ""
            )
        ) {
            XCTAssertEqual(
                $0 as? MigrationError,
                .invalidIdentifier("")
            )
        }
    }

    func testDuplicateAppliedHistoryRowsAreRejected()
        async throws
    {
        // Duplicate rows for one identifier in the database
        // history (a corrupt history state, e.g. from a lost
        // unique constraint) must surface as an explicit
        // migration error instead of crashing the unique-
        // dictionary initializer.
        let migration =
            Migration(
                id: "001",
                statements: ["SELECT 1"]
            )
        let database =
            makeHistoryDatabase(
                rows: [
                    [
                        "id": .string("001"),
                        "checksum":
                            .string(
                                migration
                                    .checksum
                            ),
                    ],
                    [
                        "id": .string("001"),
                        "checksum":
                            .string(
                                migration
                                    .checksum
                            ),
                    ],
                ]
            )
        let runner = try MigrationRunner(
            database: database
        )

        do {
            _ = try await runner.migrate([
                migration
            ])
            XCTFail(
                "Expected duplicate applied error"
            )
        } catch {
            XCTAssertEqual(
                error as? MigrationError,
                .duplicateAppliedMigration(
                    "001"
                )
            )
        }
    }

    func testPendingAppliesInAscendingIdentifierOrder()
        async throws
    {
        let store =
            MigrationStore()
        let database =
            makeDatabase(store: store)
        let runner = try MigrationRunner(
            database: database,
            clock: { 1_000 }
        )
        let migrations = [
            Migration(
                id: "003",
                statements: ["SELECT 3"]
            ),
            Migration(
                id: "001",
                statements: ["SELECT 1"]
            ),
            Migration(
                id: "002",
                statements: ["SELECT 2"]
            ),
        ]

        let status = try await runner.status(migrations)
        XCTAssertEqual(status.pending, ["001", "002", "003"])
        let dryRun = try await runner.migrate(migrations, dryRun: true)
        XCTAssertEqual(dryRun.applied, ["001", "002", "003"])
        XCTAssertFalse(database.recordedQueries.contains { $0.sql == "BEGIN" })

        let report =
            try await runner.migrate(migrations)

        // Pending migrations apply deterministically in
        // ascending identifier order regardless of the caller's
        // input ordering.
        XCTAssertEqual(
            report.applied,
            ["001", "002", "003"]
        )
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(
            database.recordedQueries.map(\.sql).filter { $0.hasPrefix("SELECT ") && !$0.contains("\"id\"") },
            ["SELECT 1", "SELECT 2", "SELECT 3"]
        )
    }

    private func makeDatabase(
        store: MigrationStore
    ) -> ScriptedDatabase {
        ScriptedDatabase {
            query in

            if query.sql.hasPrefix(
                "SELECT \"id\""
            ) {
                return DatabaseQueryResult(
                    rows: await store.rows()
                )
            }

            if query.sql.hasPrefix(
                "INSERT INTO"
            ),
               query.sql.contains(
                   "_whitethroated_migrations"
               )
            {
                guard
                    query.bindings.count >= 2
                else {
                    throw TestDatabaseError
                        .malformedInsert
                }

                let id = try String
                    .decodeDatabaseValue(
                        query.bindings[0]
                    )
                let checksum = try String
                    .decodeDatabaseValue(
                        query.bindings[1]
                    )

                await store.record(
                    id: id,
                    checksum: checksum
                )

                return .empty
            }

            if query.sql.contains("FAIL") {
                throw TestDatabaseError
                    .statementFailed
            }

            return .empty
        }
    }

    private func makeHistoryDatabase(
        rows: [DatabaseRow]
    ) -> ScriptedDatabase {
        ScriptedDatabase { query in

            if query.sql.hasPrefix(
                "SELECT \"id\""
            ) {
                return DatabaseQueryResult(
                    rows: rows
                )
            }

            return .empty
        }
    }
}

private enum TestDatabaseError:
    Error,
    Sendable
{
    case malformedInsert
    case statementFailed
}
