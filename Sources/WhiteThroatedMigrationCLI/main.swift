import Foundation
import WhiteThroatedDatabase
import WhiteThroatedMigrations
import WhiteThroatedPostgres

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@main
struct WhiteThroatedMigrationCLI {
    static func main() async {
        do {
            let command =
                try MigrationCommand.parse(
                    arguments:
                        Array(
                            CommandLine.arguments
                                .dropFirst()
                        ),
                    environment:
                        ProcessInfo.processInfo
                            .environment
                )

            if command.mode == .help {
                print(
                    MigrationCommand.usage
                )
                return
            }

            guard
                let databaseURL =
                    command.databaseURL
            else {
                throw MigrationCommandError
                    .missingDatabaseURL
            }

            let migrations =
                try MigrationFileLoader.load(
                    directory:
                        command.migrationsDirectory
                )

            let database =
                try await PostgresDatabase.connect(
                    configuration:
                        PostgresConfiguration(
                            connectionString:
                                databaseURL
                        )
                )

            do {
                let runner = try MigrationRunner(
                    database: database,
                    tableName:
                        command.tableName
                )

                switch command.mode {
                case .apply:
                    let report =
                        try await runner.migrate(
                            migrations
                        )
                    printReport(
                        report,
                        title: "Applied"
                    )

                case .dryRun:
                    let report =
                        try await runner.migrate(
                            migrations,
                            dryRun: true
                        )
                    printReport(
                        report,
                        title: "Would apply"
                    )

                case .status:
                    let status =
                        try await runner.status(
                            migrations
                        )
                    print(
                        "Applied: \(list(status.applied))"
                    )
                    print(
                        "Pending: \(list(status.pending))"
                    )

                case .help:
                    print(
                        MigrationCommand.usage
                    )
                }

                try await database.shutdown()
            } catch {
                try? await database.shutdown()
                throw error
            }
        } catch let error as MigrationCommandError {
            writeError(
                error.description
            )
            exit(2)
        } catch {
            writeError(
                String(
                    describing: error
                )
            )
            exit(1)
        }
    }

    private static func printReport(
        _ report: MigrationReport,
        title: String
    ) {
        print(
            "\(title): \(list(report.applied))"
        )
        print(
            "Skipped: \(list(report.skipped))"
        )

        if report.dryRun {
            print("Dry run: no changes were committed")
        }
    }

    private static func list(
        _ values: [String]
    ) -> String {
        values.isEmpty
            ? "(none)"
            : values.joined(
                separator: ", "
            )
    }

    private static func writeError(
        _ message: String
    ) {
        let data =
            Data(
                "\(message)\n".utf8
            )
        FileHandle.standardError
            .write(data)
    }
}
