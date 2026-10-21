import Foundation

/// An ordered, immutable schema migration.
public struct Migration:
    Sendable,
    Equatable
{
    public let id: String
    public let statements: [String]
    public let checksum: String

    public init(
        id: String,
        statements: [String]
    ) {
        precondition(
            !id.isEmpty,
            "Migration ID must not be empty"
        )

        self.id = id
        self.statements = statements
        self.checksum =
            Self.checksum(
                of: statements
            )
    }

    /// SHA-256 over the executable statements. Comments and surrounding
    /// whitespace removed by ``SQLStatementSplitter`` are not part of the
    /// checksum. Each statement is length-prefixed so different statement
    /// boundaries can never produce the same checksum input.
    public static func checksum(
        of statements: [String]
    ) -> String {
        var bytes:
            [UInt8] = []
        bytes.reserveCapacity(
            statements.reduce(0) {
                $0 + $1.utf8.count + 8
            }
        )

        for statement in statements {
            let length =
                UInt64(statement.utf8.count)

            for shift in stride(
                from: 56,
                through: 0,
                by: -8
            ) {
                bytes.append(
                    UInt8(
                        (length
                            >> UInt64(shift))
                            & 0xFF
                    )
                )
            }

            bytes.append(
                contentsOf: statement.utf8
            )
        }

        return SHA256Hex.encode(bytes)
    }
}

public struct AppliedMigration:
    Sendable,
    Equatable
{
    public let id: String
    public let checksum: String
    public let appliedAtMilliseconds: Int64

    public init(
        id: String,
        checksum: String,
        appliedAtMilliseconds: Int64
    ) {
        self.id = id
        self.checksum = checksum
        self.appliedAtMilliseconds =
            appliedAtMilliseconds
    }
}

public struct MigrationStatus:
    Sendable,
    Equatable
{
    public let applied: [String]
    public let pending: [String]

    public init(
        applied: [String],
        pending: [String]
    ) {
        self.applied = applied
        self.pending = pending
    }
}

public struct MigrationReport:
    Sendable,
    Equatable
{
    /// Migrations applied by this run, or migrations that would be applied in a
    /// dry run.
    public let applied: [String]

    /// Already-applied migrations skipped by this run.
    public let skipped: [String]

    public let dryRun: Bool

    public init(
        applied: [String],
        skipped: [String],
        dryRun: Bool
    ) {
        self.applied = applied
        self.skipped = skipped
        self.dryRun = dryRun
    }
}

public enum MigrationError:
    Error,
    Sendable,
    Equatable
{
    case duplicateID(String)
    case checksumMismatch(
        id: String,
        recorded: String,
        computed: String
    )
    case appliedMigrationNotProvided(String)
    case invalidIdentifier(String)
    case malformedAppliedMigration(
        id: String,
        reason: String
    )
}
