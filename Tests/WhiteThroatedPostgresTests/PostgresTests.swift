import Foundation
import WhiteThroatedDatabase
import WhiteThroatedMigrations
import XCTest
@testable import WhiteThroatedPostgres

/// One-shot async signal used to coordinate pool cancellation tests without
/// timing assumptions.
private actor PostgresTestSignal {
    private var isSignaled = false
    private var waiters:
        [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true

        let pending =
            waiters
        waiters.removeAll()

        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        if isSignaled {
            return
        }

        await withCheckedContinuation {
            waiters.append($0)
        }
    }
}

final class PostgresValueCodecTests: XCTestCase {
    func testParameterEncoding() throws {
        let bool =
            try PostgresValueCodec.parameter(
                .bool(true)
            )
        XCTAssertEqual(bool.text, "true")
        XCTAssertEqual(bool.type, 16)

        let int =
            try PostgresValueCodec.parameter(
                .int(-7)
            )
        XCTAssertEqual(int.text, "-7")
        XCTAssertEqual(int.type, 20)

        let double =
            try PostgresValueCodec.parameter(
                .double(.infinity)
            )
        XCTAssertEqual(double.text, "Infinity")
        XCTAssertEqual(double.type, 701)

        let string =
            try PostgresValueCodec.parameter(
                .string("hello")
            )
        XCTAssertEqual(string.text, "hello")
        XCTAssertEqual(string.type, 0)

        let uuid = UUID()
        let encodedUUID =
            try PostgresValueCodec.parameter(
                .uuid(uuid)
            )
        XCTAssertEqual(
            encodedUUID.text,
            uuid.uuidString
        )
        XCTAssertEqual(encodedUUID.type, 2950)

        let bytes =
            try PostgresValueCodec.parameter(
                .bytes([0, 255])
            )
        XCTAssertEqual(bytes.text, "\\x00ff")
        XCTAssertEqual(bytes.type, 17)

        let null =
            try PostgresValueCodec.parameter(
                .null
            )
        XCTAssertNil(null.text)
        XCTAssertEqual(null.type, 0)
    }

    func testStringWithNULIsRejected() {
        XCTAssertThrowsError(
            try PostgresValueCodec.parameter(
                .string("a\0b")
            )
        ) {
            XCTAssertEqual(
                ($0 as? DatabaseError)?.kind,
                .mapping
            )
        }
    }

    func testValueDecoding() throws {
        let bool =
            try decode(
                16,
                "t"
            )
        XCTAssertEqual(bool, .bool(true))

        let int =
            try decode(
                20,
                "-42"
            )
        XCTAssertEqual(int, .int(-42))

        let double =
            try decode(
                701,
                "1.5"
            )
        XCTAssertEqual(double, .double(1.5))

        let uuid = UUID()
        let decodedUUID =
            try decode(
                2950,
                uuid.uuidString
            )
        XCTAssertEqual(decodedUUID, .uuid(uuid))

        let bytea =
            try decode(
                17,
                "\\x00ff"
            )
        XCTAssertEqual(bytea, .bytes([0, 255]))

        let numeric =
            try decode(
                1700,
                "12.3400"
            )
        XCTAssertEqual(numeric, .string("12.3400"))

        let date =
            try decode(
                1184,
                "2026-10-21 00:00:00+00"
            )
        XCTAssertEqual(
            date,
            .string("2026-10-21 00:00:00+00")
        )
    }

    func testInvalidValuesAreMappingErrors() {
        XCTAssertThrowsError(
            try decode(16, "maybe")
        ) {
            XCTAssertEqual(
                ($0 as? DatabaseError)?.kind,
                .mapping
            )
        }

        XCTAssertThrowsError(
            try decode(20, "not-an-int")
        ) {
            XCTAssertEqual(
                ($0 as? DatabaseError)?.kind,
                .mapping
            )
        }

        XCTAssertThrowsError(
            try decode(17, "\\x0")
        ) {
            XCTAssertEqual(
                ($0 as? DatabaseError)?.kind,
                .mapping
            )
        }

        XCTAssertThrowsError(
            try decode(17, "\\777")
        ) {
            XCTAssertEqual(
                ($0 as? DatabaseError)?.kind,
                .mapping
            )
        }
    }

    func testByteaEscapeFormat() throws {
        let array =
            Array("\\000\\\\".utf8)
        let decoded =
            try array.withUnsafeBufferPointer {
                try PostgresBytes.decodeBytea(
                    $0
                )
            }
        XCTAssertEqual(
            decoded,
            [0, 92]
        )
    }

    func testErrorClassification() {
        XCTAssertEqual(
            PostgresErrorMapper.result(
                sqlState: "23505",
                message: "duplicate"
            ).kind,
            .constraint
        )
        XCTAssertEqual(
            PostgresErrorMapper.result(
                sqlState: "57014",
                message: "cancelled"
            ).kind,
            .cancelled
        )
        XCTAssertTrue(
            PostgresErrorMapper.result(
                sqlState: "40001",
                message: "retry"
            ).isTransient
        )
        XCTAssertEqual(
            PostgresErrorMapper.result(
                sqlState: "08006",
                message: "connection"
            ).kind,
            .unavailable
        )
        XCTAssertEqual(
            PostgresErrorMapper.result(
                sqlState: nil,
                message: "unknown"
            ).kind,
            .other
        )
    }

    private func decode(
        _ type: UInt32,
        _ text: String
    ) throws -> DatabaseValue {
        let array =
            Array(text.utf8)

        return try array
            .withUnsafeBufferPointer {
                try PostgresValueCodec.value(
                    type: type,
                    bytes: $0
                )
            }
    }
}

final class PostgresIntegrationTests: XCTestCase {
    func testBindingsRowsAndNulls() async throws {
        try await withDatabase {
            database in

            let table =
                uniqueName("rows")
            let quoted =
                DatabaseIdentifier.quote(table)
            let uuid = UUID()

            do {
                _ = try await database.execute(
                    """
                    CREATE TABLE \(quoted) (
                        "id" BIGINT PRIMARY KEY,
                        "active" BOOLEAN NOT NULL,
                        "name" TEXT NOT NULL,
                        "token" UUID NOT NULL,
                        "payload" BYTEA,
                        "note" TEXT
                    )
                    """
                )

                _ = try await database.execute(
                    """
                    INSERT INTO \(quoted)
                        ("id", "active", "name", "token", "payload", "note")
                    VALUES ($1, $2, $3, $4, $5, $6)
                    """,
                    [
                        .int(1),
                        .bool(true),
                        .string("Ada"),
                        .uuid(uuid),
                        .bytes([0, 1, 255]),
                        .null,
                    ]
                )

                let result =
                    try await database.execute(
                        """
                        SELECT "id", "active", "name", "token", "payload", "note"
                        FROM \(quoted)
                        WHERE "id" = $1
                        """,
                        [.int(1)]
                    )

                XCTAssertEqual(result.rows.count, 1)
                let row = result.rows[0]
                XCTAssertEqual(
                    try row.decode("id", as: Int.self),
                    1
                )
                XCTAssertEqual(
                    try row.decode("active", as: Bool.self),
                    true
                )
                XCTAssertEqual(
                    try row.decode("name", as: String.self),
                    "Ada"
                )
                XCTAssertEqual(
                    try row.decode("token", as: UUID.self),
                    uuid
                )
                XCTAssertEqual(
                    try row.decode("payload", as: [UInt8].self),
                    [0, 1, 255]
                )
                XCTAssertNil(
                    try row.decodeIfPresent(
                        "note",
                        as: String.self
                    )
                )
            } catch {
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(quoted)"
                )
                throw error
            }

            _ = try await database.execute(
                "DROP TABLE \(quoted)"
            )
        }
    }

    func testLargeBindingCountDoesNotOverflowStack() async throws {
        try await withDatabase {
            database in

            let table =
                uniqueName("bulk_bindings")
            let quoted =
                DatabaseIdentifier.quote(table)

            do {
                _ = try await database.execute(
                    """
                    CREATE TABLE \(quoted) (
                        "a" BIGINT NOT NULL,
                        "b" BIGINT NOT NULL,
                        "c" TEXT NOT NULL
                    )
                    """
                )

                let rowCount = 1200
                var placeholders:
                    [String] = []
                placeholders.reserveCapacity(
                    rowCount
                )
                var bindings:
                    [DatabaseValue] = []
                bindings.reserveCapacity(
                    rowCount * 3
                )

                for row in 0..<rowCount {
                    placeholders.append(
                        "($\(row * 3 + 1), $\(row * 3 + 2), $\(row * 3 + 3))"
                    )
                    bindings.append(
                        .int(Int64(row))
                    )
                    bindings.append(
                        .int(Int64(row) * 2)
                    )
                    bindings.append(
                        .string("row-\(row)")
                    )
                }

                let result =
                    try await database.execute(
                        DatabaseQuery(
                            """
                            INSERT INTO \(quoted) ("a", "b", "c")
                            VALUES \(placeholders.joined(separator: ", "))
                            """,
                            bindings: bindings
                        )
                    )

                XCTAssertEqual(
                    result.affectedRows,
                    rowCount
                )
            } catch {
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(quoted)"
                )
                throw error
            }

            _ = try await database.execute(
                "DROP TABLE \(quoted)"
            )
        }
    }

    func testTransactionCommitAndRollback() async throws {
        try await withDatabase {
            database in

            let table =
                uniqueName("transactions")
            let quoted =
                DatabaseIdentifier.quote(table)

            do {
                _ = try await database.execute(
                    """
                    CREATE TABLE \(quoted) (
                        "value" BIGINT NOT NULL
                    )
                    """
                )

                try await database.withTransaction {
                    connection in

                    _ = try await connection.execute(
                        """
                        INSERT INTO \(quoted) ("value") VALUES ($1)
                        """,
                        [.int(1)]
                    )
                }

                struct Rollback: Error {}

                do {
                    try await database.withTransaction {
                        connection in

                        _ = try await connection.execute(
                            """
                            INSERT INTO \(quoted) ("value") VALUES ($1)
                            """,
                            [.int(2)]
                        )
                        throw Rollback()
                    }
                    XCTFail(
                        "Expected rollback"
                    )
                } catch {
                    XCTAssertTrue(
                        error is Rollback
                    )
                }

                let result =
                    try await database.execute(
                        """
                        SELECT "value" FROM \(quoted) ORDER BY "value"
                        """
                    )

                XCTAssertEqual(
                    result.rows.compactMap {
                        try? $0.decode(
                            "value",
                            as: Int.self
                        )
                    },
                    [1]
                )
            } catch {
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(quoted)"
                )
                throw error
            }

            _ = try await database.execute(
                "DROP TABLE \(quoted)"
            )
        }
    }

    func testLeakedTransactionIsRolledBackOnRelease() async throws {
        try await withDatabase(poolSize: 1) {
            database in

            let table =
                uniqueName("leaked_transaction")
            let quoted =
                DatabaseIdentifier.quote(table)

            do {
                _ = try await database.execute(
                    """
                    CREATE TABLE \(quoted) (
                        "value" BIGINT NOT NULL
                    )
                    """
                )

                _ = try await database.withConnection {
                    connection in

                    _ = try await connection.execute(
                        "BEGIN"
                    )
                    _ = try await connection.execute(
                        """
                        INSERT INTO \(quoted) ("value") VALUES (1)
                        """
                    )
                    // Deliberately leave the transaction open. The pool must
                    // roll it back before leasing this connection again.
                }

                let result =
                    try await database.execute(
                        """
                        SELECT COUNT(*) AS "count" FROM \(quoted)
                        """
                    )
                XCTAssertEqual(
                    try result.rows[0].decode(
                        "count",
                        as: Int.self
                    ),
                    0
                )
            } catch {
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(quoted)"
                )
                throw error
            }

            _ = try await database.execute(
                "DROP TABLE \(quoted)"
            )
        }
    }

    func testConstraintErrorsAreMapped() async throws {
        try await withDatabase {
            database in

            let table =
                uniqueName("constraint")
            let quoted =
                DatabaseIdentifier.quote(table)

            do {
                _ = try await database.execute(
                    """
                    CREATE TABLE \(quoted) (
                        "id" BIGINT PRIMARY KEY
                    )
                    """
                )
                _ = try await database.execute(
                    """
                    INSERT INTO \(quoted) ("id") VALUES ($1)
                    """,
                    [.int(1)]
                )

                do {
                    _ = try await database.execute(
                        """
                        INSERT INTO \(quoted) ("id") VALUES ($1)
                        """,
                        [.int(1)]
                    )
                    XCTFail(
                        "Expected a constraint error"
                    )
                } catch let error as DatabaseError {
                    XCTAssertEqual(
                        error.kind,
                        .constraint
                    )
                    XCTAssertEqual(
                        error.code,
                        "23505"
                    )
                }
            } catch {
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(quoted)"
                )
                throw error
            }

            _ = try await database.execute(
                "DROP TABLE \(quoted)"
            )
        }
    }

    func testCancellationPropagates() async throws {
        try await withDatabase {
            database in

            let task =
                Task {
                    try await database.execute(
                        "SELECT pg_sleep(5)"
                    )
                }

            try await Task.sleep(
                nanoseconds: 200_000_000
            )
            task.cancel()

            do {
                _ = try await task.value
                XCTFail(
                    "Expected cancellation"
                )
            } catch is CancellationError {
                // Expected.
            }
        }
    }

    func testCancelledLeaseWaitIsRemovedFromQueue() async throws {
        try await withDatabase(poolSize: 1) {
            database in

            let holderStarted =
                PostgresTestSignal()
            let releaseHolder =
                PostgresTestSignal()

            let holder =
                Task {
                    try await database.withConnection {
                        _ in

                        await holderStarted.signal()
                        await releaseHolder.wait()
                    }
                }

            await holderStarted.wait()

            var waiting =
                await database.waitingLeaseCount
            XCTAssertEqual(waiting, 0)

            let waiter =
                Task { () -> Bool in
                    do {
                        try await database.withConnection {
                            _ in

                            XCTFail(
                                "A cancelled waiter must not receive a connection"
                            )
                        }
                        return true
                    } catch is CancellationError {
                        return false
                    }
                }

            var spins = 0
            waiting =
                await database.waitingLeaseCount

            while waiting == 0,
                  spins < 10_000
            {
                await Task.yield()
                waiting =
                    await database.waitingLeaseCount
                spins += 1
            }

            XCTAssertEqual(waiting, 1)
            waiter.cancel()

            spins = 0

            while waiting > 0,
                  spins < 10_000
            {
                await Task.yield()
                waiting =
                    await database.waitingLeaseCount
                spins += 1
            }

            XCTAssertEqual(waiting, 0)

            await releaseHolder.signal()

            let received =
                try await waiter.value
            XCTAssertFalse(received)
            try await holder.value
        }
    }

    func testConcurrentPoolUse() async throws {
        try await withDatabase {
            database in

            try await withThrowingTaskGroup(
                of: Int.self
            ) {
                group in

                for value in 1...8 {
                    group.addTask {
                        let result =
                            try await database.execute(
                                "SELECT $1::bigint AS \"value\"",
                                [.int(Int64(value))]
                            )
                        return try result.rows[0]
                            .decode(
                                "value",
                                as: Int.self
                            )
                    }
                }

                var values:
                    [Int] = []
                for try await value in group {
                    values.append(value)
                }

                XCTAssertEqual(
                    values.sorted(),
                    Array(1...8)
                )
            }
        }
    }

    func testMigrationRunnerAppliesAndSkips() async throws {
        try await withDatabase {
            database in

            let table =
                uniqueName("migration_table")
            let tracking =
                uniqueName("migration_history")
            let quoted =
                DatabaseIdentifier.quote(table)
            let migrations = [
                Migration(
                    id: "001",
                    statements: [
                        """
                        CREATE TABLE \(quoted) (
                            "id" BIGINT PRIMARY KEY
                        )
                        """
                    ]
                ),
                Migration(
                    id: "002",
                    statements: [
                        """
                        INSERT INTO \(quoted) ("id") VALUES (1)
                        """
                    ]
                ),
            ]

            do {
                let runner =
                    try MigrationRunner(
                        database: database,
                        tableName: tracking
                    )
                let first =
                    try await runner.migrate(
                        migrations
                    )
                XCTAssertEqual(
                    first.applied,
                    ["001", "002"]
                )

                let second =
                    try await runner.migrate(
                        migrations
                    )
                XCTAssertEqual(
                    second.applied,
                    []
                )
                XCTAssertEqual(
                    second.skipped,
                    ["001", "002"]
                )

                let status =
                    try await runner.status(
                        migrations
                    )
                XCTAssertEqual(
                    status.pending,
                    []
                )
            } catch {
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(quoted)"
                )
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(DatabaseIdentifier.quote(tracking))"
                )
                throw error
            }

            _ = try await database.execute(
                "DROP TABLE \(quoted)"
            )
            _ = try await database.execute(
                "DROP TABLE \(DatabaseIdentifier.quote(tracking))"
            )
        }
    }

    func testMigrationLockSerializesConcurrentRunners() async throws {
        // poolSize 1 deadlocked when the lock used a pooled connection,
        // because the waiting runner held the connection the lock holder
        // needed for its own migrations.
        try await withDatabase(poolSize: 1) {
            database in

            let table =
                uniqueName("migration_lock_table")
            let tracking =
                uniqueName("migration_lock_history")
            let quoted =
                DatabaseIdentifier.quote(table)
            let migrations = [
                Migration(
                    id: "001",
                    statements: [
                        """
                        CREATE TABLE \(quoted) (
                            "id" BIGINT PRIMARY KEY
                        )
                        """
                    ]
                ),
                Migration(
                    id: "002",
                    statements: [
                        """
                        INSERT INTO \(quoted) ("id") VALUES (1)
                        """
                    ]
                ),
            ]

            do {
                let runner =
                    try MigrationRunner(
                        database: database,
                        tableName: tracking
                    )

                async let first =
                    runner.migrate(migrations)
                async let second =
                    runner.migrate(migrations)
                let reports =
                    try await [first, second]

                XCTAssertEqual(
                    reports
                        .flatMap(\.applied)
                        .sorted(),
                    ["001", "002"]
                )
                XCTAssertEqual(
                    reports.map(\.applied.count)
                        .reduce(0, +),
                    2
                )
            } catch {
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(quoted)"
                )
                _ = try? await database.execute(
                    "DROP TABLE IF EXISTS \(DatabaseIdentifier.quote(tracking))"
                )
                throw error
            }

            _ = try await database.execute(
                "DROP TABLE \(quoted)"
            )
            _ = try await database.execute(
                "DROP TABLE \(DatabaseIdentifier.quote(tracking))"
            )
        }
    }

    func testMigrationLockWorksWithPoolSizeOne() async throws {
        try await withDatabase(poolSize: 1) {
            database in

            let value =
                try await database.withMigrationLock {
                    7
                }
            XCTAssertEqual(value, 7)
        }
    }

    func testSessionConfigurationIsDeterministic() async throws {
        try await withDatabase {
            database in

            let settings =
                try await database.execute(
                    """
                    SELECT
                        current_setting('client_encoding') AS "encoding",
                        current_setting('standard_conforming_strings') AS "strings",
                        current_setting('bytea_output') AS "bytea"
                    """
                )

            XCTAssertEqual(
                try settings.rows[0].decode(
                    "encoding",
                    as: String.self
                ),
                "UTF8"
            )
            XCTAssertEqual(
                try settings.rows[0].decode(
                    "strings",
                    as: String.self
                ),
                "on"
            )
            XCTAssertEqual(
                try settings.rows[0].decode(
                    "bytea",
                    as: String.self
                ),
                "hex"
            )
        }
    }

    func testShutdownIsIdempotent() async throws {
        guard
            let url =
                ProcessInfo.processInfo
                    .environment[
                        "WHITETHROATED_POSTGRES_URL"
                    ]
        else {
            throw XCTSkip(
                "Set WHITETHROATED_POSTGRES_URL to run Postgres integration tests"
            )
        }

        let database =
            try await PostgresDatabase.connect(
                configuration:
                    PostgresConfiguration(
                        connectionString: url
                    )
            )

        try await database.shutdown()
        try await database.shutdown()
    }

    private func withDatabase<T>(
        poolSize: Int = 4,
        _ body: (PostgresDatabase) async throws -> T
    ) async throws -> T {
        guard
            let url =
                ProcessInfo.processInfo
                    .environment[
                        "WHITETHROATED_POSTGRES_URL"
                    ]
        else {
            throw XCTSkip(
                "Set WHITETHROATED_POSTGRES_URL to run Postgres integration tests"
            )
        }

        let database =
            try await PostgresDatabase.connect(
                configuration:
                    PostgresConfiguration(
                        connectionString: url,
                        poolSize: poolSize
                    )
            )

        do {
            let value =
                try await body(database)
            try await database.shutdown()
            return value
        } catch {
            try? await database.shutdown()
            throw error
        }
    }

    private func uniqueName(
        _ prefix: String
    ) -> String {
        "wt_\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
