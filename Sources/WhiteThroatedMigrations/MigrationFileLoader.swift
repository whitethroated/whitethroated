import Foundation

public enum MigrationFileError:
    Error,
    Sendable,
    Equatable
{
    case unreadableDirectory(String)
    case unreadableFile(String)
    case invalidUTF8(String)
    case invalidSQL(String)
    case duplicateID(String)
}

public enum MigrationFileLoader {
    public static func load(
        directory: String
    ) throws -> [Migration] {
        try load(
            directory: URL(
                fileURLWithPath: directory,
                isDirectory: true
            )
        )
    }

    public static func load(
        directory: URL
    ) throws -> [Migration] {
        let fileManager =
            FileManager.default

        let names: [String]

        do {
            names = try fileManager
                .contentsOfDirectory(
                    atPath: directory.path
                )
        } catch {
            throw MigrationFileError
                .unreadableDirectory(
                    directory.path
                )
        }

        let sqlNames =
            names
                .filter {
                    $0.lowercased()
                        .hasSuffix(".sql")
                }
                .sorted()

        var migrations:
            [Migration] = []
        migrations.reserveCapacity(
            sqlNames.count
        )
        var identifiers =
            Set<String>()

        for name in sqlNames {
            let id =
                URL(fileURLWithPath: name)
                    .deletingPathExtension()
                    .lastPathComponent

            guard identifiers.insert(id).inserted else {
                throw MigrationFileError
                    .duplicateID(id)
            }

            let path =
                directory
                    .appendingPathComponent(name)
                    .path
            let data: Data

            do {
                data = try Data(
                    contentsOf: URL(
                        fileURLWithPath: path
                    )
                )
            } catch {
                throw MigrationFileError
                    .unreadableFile(path)
            }

            guard let sql = String(
                data: data,
                encoding: .utf8
            ) else {
                throw MigrationFileError
                    .invalidUTF8(path)
            }

            let statements: [String]

            do {
                statements =
                    try SQLStatementSplitter
                        .split(sql)
            } catch {
                throw MigrationFileError
                    .invalidSQL(path)
            }

            migrations.append(
                Migration(
                    id: id,
                    statements: statements
                )
            )
        }

        return migrations
    }
}
