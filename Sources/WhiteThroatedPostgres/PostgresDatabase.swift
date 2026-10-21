import WhiteThroatedDatabase

/// A pooled PostgreSQL database backed by the system libpq client library.
///
/// libpq is synchronous. The adapter confines every libpq call to a dedicated
/// serial dispatch queue per connection, so callers on SwiftNIO event loops
/// never block. The public API remains async/await and exposes explicit
/// connection leases and transaction boundaries through ``Database``.
public final class PostgresDatabase:
    Database,
    DatabaseMigrationLocking,
    Sendable
{
    public let configuration:
        PostgresConfiguration

    private let pool:
        PostgresConnectionPool

    private init(
        configuration: PostgresConfiguration
    ) {
        self.configuration = configuration
        self.pool =
            PostgresConnectionPool(
                configuration: configuration
            )
    }

    /// Create a pool and validate that at least one connection can be opened.
    public static func connect(
        configuration: PostgresConfiguration
    ) async throws -> PostgresDatabase {
        let database =
            PostgresDatabase(
                configuration: configuration
            )

        do {
            try await database.pool
                .validate()
            return database
        } catch {
            await database.pool
                .shutdown()
            throw error
        }
    }

    public func execute(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult {
        try await withConnection {
            connection in

            try await connection.execute(
                query
            )
        }
    }

    /// Number of callers currently waiting for a pooled connection.
    ///
    /// Internal so tests can wait for a cancellation to remove a queued lease
    /// without relying on timing.
    var waitingLeaseCount: Int {
        get async {
            await pool.waiterCount
        }
    }

    public func withConnection<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseConnection
        ) async throws -> T
    ) async throws -> T {
        let connection =
            try await pool.lease()

        do {
            let value =
                try await body(connection)
            await pool.release(
                connection
            )
            return value
        } catch {
            await pool.release(
                connection
            )
            throw error
        }
    }

    public func shutdown() async throws {
        await pool.shutdown()
    }

    public func withMigrationLock<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // The lock must not occupy a pooled connection. A second migration
        // runner waiting inside `pg_advisory_lock` would otherwise hold the
        // connection that the lock holder needs to run its own migrations,
        // which deadlocks as soon as concurrent runners reach pool capacity.
        // A dedicated connection keeps the pool available to the body.
        let lockConnection =
            try await PostgresConnection.connect(
                configuration: configuration
            )

        do {
            _ = try await lockConnection.execute(
                PostgresDatabase.migrationLockQuery
            )
        } catch {
            lockConnection.invalidate()
            await lockConnection.close()
            throw error
        }

        let bodyResult:
            Result<T, Error>

        do {
            bodyResult = .success(
                try await body()
            )
        } catch {
            bodyResult = .failure(error)
        }

        do {
            try await Self.unlockMigration(
                on: lockConnection
            )
        } catch {
            lockConnection.invalidate()
            await lockConnection.close()

            switch bodyResult {
            case .success:
                throw error

            case .failure(let bodyError):
                throw bodyError
            }
        }

        await lockConnection.close()
        return try bodyResult.get()
    }

    private static func unlockMigration(
        on connection: PostgresConnection
    ) async throws {
        let result =
            try await connection
                .executeWithoutCancellation(
                    migrationUnlockQuery
                )

        guard
            let row = result.rows.first,
            let unlocked = try? row.decode(
                "unlocked",
                as: Bool.self
            )
        else {
            throw DatabaseError(
                kind: .transaction,
                message:
                    "Postgres migration lock did not return a boolean"
            )
        }

        guard unlocked else {
            throw DatabaseError(
                kind: .transaction,
                message:
                    "Postgres migration advisory lock was not held"
            )
        }
    }

    private static let migrationLockQuery =
        DatabaseQuery(
            """
            SELECT pg_advisory_lock(
                hashtextextended(
                    'whitethroated:migrations:' || current_database(),
                    0
                )
            )
            """
        )

    private static let migrationUnlockQuery =
        DatabaseQuery(
            """
            SELECT pg_advisory_unlock(
                hashtextextended(
                    'whitethroated:migrations:' || current_database(),
                    0
                )
            ) AS "unlocked"
            """
        )
}
