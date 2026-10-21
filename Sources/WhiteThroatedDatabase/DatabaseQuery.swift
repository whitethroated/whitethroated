/// A parameterized SQL statement.
///
/// Bindings are positional and use one-based placeholders: `$1`, `$2`, and so
/// on. The database contract uses this notation regardless of adapter. An
/// adapter must translate it only when its native protocol requires another
/// form.
public struct DatabaseQuery:
    Sendable,
    Equatable
{
    public let sql: String
    public let bindings: [DatabaseValue]

    public init(
        _ sql: String,
        bindings: [DatabaseValue] = []
    ) {
        self.sql = sql
        self.bindings = bindings
    }
}

public struct DatabaseQueryResult:
    Sendable,
    Equatable
{
    public let rows: [DatabaseRow]

    /// Number of rows affected by an INSERT, UPDATE, or DELETE when the adapter
    /// reports it. It is `nil` for adapters or statements that do not provide a
    /// command tag.
    public let affectedRows: Int?

    public init(
        rows: [DatabaseRow] = [],
        affectedRows: Int? = nil
    ) {
        self.rows = rows
        self.affectedRows =
            affectedRows
    }

    public static let empty =
        DatabaseQueryResult()
}
