import WhiteThroatedDatabase

public enum DatabaseRepositoryError:
    Error,
    Sendable,
    Equatable
{
    case emptyColumns
    case duplicateColumn(String)
    case primaryKeyNotInColumns(String)
    case missingModelValue(String)
    case noMutableColumns
}

/// Explicit CRUD operations for one ``DatabaseModel``.
///
/// SQL is built and quoted once during setup. Each operation receives a
/// connection explicitly, so repository instances can be used with a pool or a
/// transaction without hidden global state.
public struct DatabaseRepository<Model: DatabaseModel>:
    Sendable
{
    public let connection:
        any DatabaseConnection

    private let mutableColumns: [String]
    private let selectAllSQL: String
    private let selectByIDSQL: String
    private let insertSQL: String
    private let updateSQL: String
    private let deleteSQL: String

    public init(
        connection: any DatabaseConnection,
        model: Model.Type = Model.self
    ) throws {
        let columns = Model.columns

        guard !columns.isEmpty else {
            throw DatabaseRepositoryError
                .emptyColumns
        }

        var seen =
            Set<String>()
        seen.reserveCapacity(
            columns.count
        )

        for column in columns {
            guard seen.insert(column).inserted else {
                throw DatabaseRepositoryError
                    .duplicateColumn(column)
            }
        }

        let primaryKey =
            Model.primaryKeyColumn

        guard seen.contains(primaryKey) else {
            throw DatabaseRepositoryError
                .primaryKeyNotInColumns(
                    primaryKey
                )
        }

        let mutable =
            columns.filter {
                $0 != primaryKey
            }

        guard !mutable.isEmpty else {
            throw DatabaseRepositoryError
                .noMutableColumns
        }

        let table =
            DatabaseIdentifier.quote(
                Model.tableName
            )
        let quotedColumns =
            DatabaseIdentifier.quote(
                columns
            )
        let quotedMutable =
            mutable.map {
                DatabaseIdentifier.quote($0)
            }
        let quotedPrimaryKey =
            DatabaseIdentifier.quote(
                primaryKey
            )

        let insertPlaceholders =
            Self.placeholders(
                count: columns.count,
                startingAt: 1
            )

        self.connection = connection
        self.mutableColumns = mutable
        self.selectAllSQL =
            "SELECT \(quotedColumns) FROM \(table)"
        self.selectByIDSQL =
            """
            SELECT \(quotedColumns) FROM \(table) \
            WHERE \(quotedPrimaryKey) = $1 LIMIT 1
            """
        self.insertSQL =
            """
            INSERT INTO \(table) (\(quotedColumns)) \
            VALUES (\(insertPlaceholders))
            """
        self.updateSQL =
            """
            UPDATE \(table) SET \(Self.assignments(
                columns: quotedMutable
            )) WHERE \(quotedPrimaryKey) = $\(mutable.count + 1)
            """
        self.deleteSQL =
            """
            DELETE FROM \(table) \
            WHERE \(quotedPrimaryKey) = $1
            """
    }

    public func all() async throws -> [Model] {
        let result =
            try await connection.execute(
                DatabaseQuery(
                    selectAllSQL
                )
            )

        return try result.rows.map {
            try Model(
                databaseRow: $0
            )
        }
    }

    public func find(
        _ id: Model.ID
    ) async throws -> Model? {
        let result =
            try await connection.execute(
                DatabaseQuery(
                    selectByIDSQL,
                    bindings: [
                        id.databaseValue
                    ]
                )
            )

        guard let row = result.rows.first else {
            return nil
        }

        return try Model(
            databaseRow: row
        )
    }

    @discardableResult
    public func insert(
        _ model: Model
    ) async throws -> DatabaseQueryResult {
        let values =
            try model.databaseValues()
        let bindings =
            try Model.columns.map {
                column in

                guard let value = values[column] else {
                    throw DatabaseRepositoryError
                        .missingModelValue(
                            column
                        )
                }

                return value
            }

        return try await connection.execute(
            DatabaseQuery(
                insertSQL,
                bindings: bindings
            )
        )
    }

    @discardableResult
    public func update(
        _ model: Model
    ) async throws -> DatabaseQueryResult {
        let values =
            try model.databaseValues()

        var bindings:
            [DatabaseValue] = []
        bindings.reserveCapacity(
            mutableColumns.count + 1
        )

        for column in mutableColumns {
            guard let value = values[column] else {
                throw DatabaseRepositoryError
                    .missingModelValue(column)
            }

            bindings.append(value)
        }

        guard
            let primaryKeyValue =
                values[Model.primaryKeyColumn]
        else {
            throw DatabaseRepositoryError
                .missingModelValue(
                    Model.primaryKeyColumn
                )
        }

        bindings.append(primaryKeyValue)

        return try await connection.execute(
            DatabaseQuery(
                updateSQL,
                bindings: bindings
            )
        )
    }

    @discardableResult
    public func delete(
        _ id: Model.ID
    ) async throws -> DatabaseQueryResult {
        try await connection.execute(
            DatabaseQuery(
                deleteSQL,
                bindings: [
                    id.databaseValue
                ]
            )
        )
    }

    private static func placeholders(
        count: Int,
        startingAt start: Int
    ) -> String {
        (start..<(start + count))
            .map {
                "$\($0)"
            }
            .joined(separator: ", ")
    }

    private static func assignments(
        columns: [String]
    ) -> String {
        var output:
            [String] = []
        output.reserveCapacity(
            columns.count
        )

        for (index, column) in columns.enumerated() {
            output.append(
                "\(column) = $\(index + 1)"
            )
        }

        return output.joined(
            separator: ", "
        )
    }
}
