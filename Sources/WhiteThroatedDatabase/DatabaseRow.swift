/// A decoded database row keyed by column name.
///
/// Duplicate column names from a query collapse to the last value. Use an
/// explicit alias in SQL when a result needs both values.
public struct DatabaseRow:
    Sendable,
    Equatable,
    ExpressibleByDictionaryLiteral
{
    public let values:
        [String: DatabaseValue]

    public var columnNames: [String] {
        Array(values.keys)
    }

    public var count: Int {
        values.count
    }

    public init(
        _ values: [String: DatabaseValue]
    ) {
        self.values = values
    }

    public init(
        dictionaryLiteral elements:
            (String, DatabaseValue)...
    ) {
        var values:
            [String: DatabaseValue] = [:]
        values.reserveCapacity(
            elements.count
        )

        for (name, value) in elements {
            values[name] = value
        }

        self.values = values
    }

    public subscript(
        _ column: String
    ) -> DatabaseValue? {
        values[column]
    }

    public func require(
        _ column: String
    ) throws -> DatabaseValue {
        guard let value = values[column] else {
            throw DatabaseRowError
                .missingColumn(column)
        }

        return value
    }

    public func decode<T: DatabaseValueConvertible>(
        _ column: String,
        as type: T.Type = T.self
    ) throws -> T {
        try T.decodeDatabaseValue(
            require(column)
        )
    }

    public func decodeIfPresent<T: DatabaseValueConvertible>(
        _ column: String,
        as type: T.Type = T.self
    ) throws -> T? {
        let value = try require(column)

        if value.isNull {
            return nil
        }

        return try T.decodeDatabaseValue(
            value
        )
    }
}

public enum DatabaseRowError:
    Error,
    Sendable,
    Equatable
{
    case missingColumn(String)
}
