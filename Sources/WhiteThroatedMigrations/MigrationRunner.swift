import Foundation
import WhiteThroatedDatabase

public struct MigrationRunner:
    Sendable
{
    public typealias Clock =
        @Sendable () -> Int64

    public let database: any Database
    public let tableName: String

    private let clock: Clock

    public init(
        database: any Database,
        tableName: String =
            "_whitethroated_migrations",
        clock: @escaping Clock = {
            Int64(
                Date()
                    .timeIntervalSince1970
                    * 1_000
            )
        }
    ) throws {
        guard
            !tableName.isEmpty,
            !tableName.utf8.contains(0)
        else {
            throw MigrationError
                .invalidIdentifier(
                    tableName
                )
        }

        self.database = database
        self.tableName = tableName
        self.clock = clock
    }

    public func status(
        _ migrations: [Migration]
    ) async throws -> MigrationStatus {
        try validateUniqueIDs(
            migrations
        )

        try await ensureSchema()

        let applied =
            try await loadApplied()
        let plan = try makePlan(
            migrations: migrations,
            applied: applied
        )

        return MigrationStatus(
            applied: plan.skipped,
            pending: plan.pending
                .map(\.id)
        )
    }

    public func migrate(
        _ migrations: [Migration],
        dryRun: Bool = false
    ) async throws -> MigrationReport {
        let body: @Sendable () async throws
            -> MigrationReport = {
                try await migrateLocked(
                    migrations,
                    dryRun: dryRun
                )
            }

        if let locking =
            database
                as? any DatabaseMigrationLocking
        {
            return try await locking
                .withMigrationLock(body)
        }

        return try await body()
    }

    private func migrateLocked(
        _ migrations: [Migration],
        dryRun: Bool
    ) async throws -> MigrationReport {
        try validateUniqueIDs(
            migrations
        )

        try await ensureSchema()

        let applied =
            try await loadApplied()
        let plan = try makePlan(
            migrations: migrations,
            applied: applied
        )

        guard !dryRun else {
            return MigrationReport(
                applied: plan.pending
                    .map(\.id),
                skipped:
                    plan.skipped,
                dryRun: true
            )
        }

        var appliedIDs:
            [String] = []
        appliedIDs.reserveCapacity(
            plan.pending.count
        )

        for migration in plan.pending {
            try Task.checkCancellation()

            let appliedAt =
                clock()

            try await database
                .withTransaction {
                    transaction in

                    for statement in migration
                        .statements
                    {
                        _ = try await transaction
                            .execute(
                                DatabaseQuery(
                                    statement
                                )
                            )
                    }

                    _ = try await transaction
                        .execute(
                            DatabaseQuery(
                                """
                                INSERT INTO \(self.quotedTableName) \
                                ("id", "checksum", "applied_at") \
                                VALUES ($1, $2, $3)
                                """,
                                bindings: [
                                    .string(migration.id),
                                    .string(migration.checksum),
                                    .int(appliedAt),
                                ]
                            )
                        )
                }

            appliedIDs.append(
                migration.id
            )
        }

        return MigrationReport(
            applied: appliedIDs,
            skipped: plan.skipped,
            dryRun: false
        )
    }

    private var quotedTableName: String {
        DatabaseIdentifier.quote(
            tableName
        )
    }

    private func ensureSchema() async throws {
        _ = try await database.execute(
            DatabaseQuery(
                """
                CREATE TABLE IF NOT EXISTS \(quotedTableName) (
                    "id" TEXT PRIMARY KEY,
                    "checksum" TEXT NOT NULL,
                    "applied_at" BIGINT NOT NULL
                )
                """
            )
        )
    }

    private func loadApplied() async throws
        -> [AppliedMigration]
    {
        let result =
            try await database.execute(
                DatabaseQuery(
                    """
                    SELECT "id", "checksum" \
                    FROM \(quotedTableName) \
                    ORDER BY "id"
                    """
                )
            )

        var applied:
            [AppliedMigration] = []
        applied.reserveCapacity(
            result.rows.count
        )

        for row in result.rows {
            let id: String

            do {
                id = try row.decode(
                    "id",
                    as: String.self
                )
            } catch {
                throw MigrationError
                    .malformedAppliedMigration(
                        id: "<unknown>",
                        reason: String(
                            describing: error
                        )
                    )
            }

            do {
                let checksum = try row.decode(
                    "checksum",
                    as: String.self
                )

                applied.append(
                    AppliedMigration(
                        id: id,
                        checksum: checksum,
                        appliedAtMilliseconds: 0
                    )
                )
            } catch {
                throw MigrationError
                    .malformedAppliedMigration(
                        id: id,
                        reason: String(
                            describing: error
                        )
                    )
            }
        }

        return applied
    }

    private func makePlan(
        migrations: [Migration],
        applied: [AppliedMigration]
    ) throws -> (
        skipped: [String],
        pending: [Migration]
    ) {
        let migrationByID =
            Dictionary(
                uniqueKeysWithValues:
                    migrations.map {
                        ($0.id, $0)
                    }
            )
        // The applied history comes from the database, so duplicate
        // records for one identifier are a possible corrupt
        // history condition; detect them instead of crashing in
        // the unique-dictionary initializer.
        var appliedByID:
            [String: AppliedMigration] = [:]
        appliedByID.reserveCapacity(
            applied.count
        )

        for record in applied {
            guard appliedByID[record.id]
                == nil
            else {
                throw MigrationError
                    .duplicateAppliedMigration(
                        record.id
                    )
            }

            appliedByID[record.id] = record
        }

        for record in applied {
            guard let migration =
                migrationByID[record.id]
            else {
                throw MigrationError
                    .appliedMigrationNotProvided(
                        record.id
                    )
            }

            guard migration.checksum
                == record.checksum
            else {
                throw MigrationError
                    .checksumMismatch(
                        id: record.id,
                        recorded: record.checksum,
                        computed: migration.checksum
                    )
            }
        }

        var skipped:
            [String] = []
        var pending:
            [Migration] = []
        skipped.reserveCapacity(
            applied.count
        )
        pending.reserveCapacity(
            migrations.count - applied.count
        )

        for migration in migrations {
            if appliedByID[migration.id] != nil {
                skipped.append(
                    migration.id
                )
            } else {
                pending.append(
                    migration
                )
            }
        }

        // Apply pending migrations in ascending identifier
        // order regardless of how the caller ordered the
        // input, so the recorded history is deterministic.
        pending.sort {
            $0.id < $1.id
        }

        return (
            skipped,
            pending
        )
    }

    private func validateUniqueIDs(
        _ migrations: [Migration]
    ) throws {
        var identifiers =
            Set<String>()
        identifiers.reserveCapacity(
            migrations.count
        )

        for migration in migrations {
            guard identifiers
                .insert(migration.id)
                .inserted
            else {
                throw MigrationError
                    .duplicateID(
                        migration.id
                    )
            }
        }
    }
}
