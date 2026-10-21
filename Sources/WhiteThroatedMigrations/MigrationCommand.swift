public struct MigrationCommand:
    Sendable,
    Equatable
{
    public enum Mode:
        String,
        Sendable
    {
        case apply
        case dryRun
        case status
        case help
    }

    public let mode: Mode
    public let databaseURL: String?
    public let migrationsDirectory: String
    public let tableName: String

    public init(
        mode: Mode,
        databaseURL: String?,
        migrationsDirectory: String =
            "Migrations",
        tableName: String =
            "_whitethroated_migrations"
    ) {
        self.mode = mode
        self.databaseURL =
            databaseURL
        self.migrationsDirectory =
            migrationsDirectory
        self.tableName = tableName
    }

    public static func parse(
        arguments: [String],
        environment: [String: String]
    ) throws -> MigrationCommand {
        if arguments.contains("--help")
            || arguments.contains("-h")
        {
            return MigrationCommand(
                mode: .help,
                databaseURL:
                    environment["DATABASE_URL"]
            )
        }

        var databaseURL =
            environment["DATABASE_URL"]
                ?? environment[
                    "WHITETHROATED_DATABASE_URL"
                ]
        var migrationsDirectory =
            "Migrations"
        var tableName =
            "_whitethroated_migrations"
        var wantsStatus = false
        var wantsDryRun = false
        var index = 0

        while index < arguments.count {
            let argument =
                arguments[index]

            switch argument {
            case "--status":
                wantsStatus = true
                index += 1

            case "--dry-run":
                wantsDryRun = true
                index += 1

            case "--database-url":
                databaseURL = try value(
                    for: argument,
                    arguments: arguments,
                    index: &index
                )

            case "--migrations":
                migrationsDirectory = try value(
                    for: argument,
                    arguments: arguments,
                    index: &index
                )

            case "--table":
                tableName = try value(
                    for: argument,
                    arguments: arguments,
                    index: &index
                )

            default:
                if argument.hasPrefix(
                    "--database-url="
                ) {
                    databaseURL =
                        String(
                            argument.dropFirst(
                                "--database-url="
                                    .count
                            )
                        )
                    index += 1
                } else if argument.hasPrefix(
                    "--migrations="
                ) {
                    migrationsDirectory =
                        String(
                            argument.dropFirst(
                                "--migrations="
                                    .count
                            )
                        )
                    index += 1
                } else if argument.hasPrefix(
                    "--table="
                ) {
                    tableName =
                        String(
                            argument.dropFirst(
                                "--table=".count
                            )
                        )
                    index += 1
                } else {
                    throw MigrationCommandError
                        .unexpectedArgument(
                            argument
                        )
                }
            }
        }

        if wantsStatus && wantsDryRun {
            throw MigrationCommandError
                .conflictingModes
        }

        guard
            let databaseURL,
            !databaseURL.isEmpty
        else {
            throw MigrationCommandError
                .missingDatabaseURL
        }

        if migrationsDirectory.isEmpty {
            throw MigrationCommandError
                .emptyValue("--migrations")
        }

        if tableName.isEmpty {
            throw MigrationCommandError
                .emptyValue("--table")
        }

        let mode:
            Mode

        if wantsStatus {
            mode = .status
        } else if wantsDryRun {
            mode = .dryRun
        } else {
            mode = .apply
        }

        return MigrationCommand(
            mode: mode,
            databaseURL: databaseURL,
            migrationsDirectory:
                migrationsDirectory,
            tableName: tableName
        )
    }

    public static let usage =
        """
        Usage: whitethroated-migrate [options]

        Options:
          --database-url <url>   Postgres URL. Defaults to DATABASE_URL or
                                 WHITETHROATED_DATABASE_URL.
          --migrations <path>    Directory containing *.sql files.
                                 Defaults to ./Migrations.
          --table <name>         Migration tracking table.
                                 Defaults to _whitethroated_migrations.
          --status               Print applied and pending migrations.
          --dry-run              Print migrations that would be applied.
          --help, -h             Show this help.

        Files are applied in lexicographic filename order. Each file is one
        migration; its filename without .sql is the migration ID.
        """

    private static func value(
        for flag: String,
        arguments: [String],
        index: inout Int
    ) throws -> String {
        let valueIndex =
            index + 1

        guard valueIndex < arguments.count else {
            throw MigrationCommandError
                .missingValue(flag)
        }

        let value =
            arguments[valueIndex]

        guard !value.isEmpty else {
            throw MigrationCommandError
                .emptyValue(flag)
        }

        index = valueIndex + 1
        return value
    }
}

public enum MigrationCommandError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case missingDatabaseURL
    case missingValue(String)
    case emptyValue(String)
    case unexpectedArgument(String)
    case conflictingModes

    public var description: String {
        switch self {
        case .missingDatabaseURL:
            return "A Postgres database URL is required"
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .emptyValue(let flag):
            return "Empty value for \(flag)"
        case .unexpectedArgument(let argument):
            return "Unexpected argument: \(argument)"
        case .conflictingModes:
            return "--status and --dry-run cannot be combined"
        }
    }
}
