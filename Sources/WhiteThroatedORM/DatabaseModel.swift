import WhiteThroatedDatabase

/// A row-mapped model with an explicit schema.
///
/// Models do not open connections or run queries when properties are read.
/// Repository operations are the only database boundary.
public protocol DatabaseModel:
    Sendable
{
    associatedtype ID: DatabaseValueConvertible

    static var tableName: String { get }
    static var primaryKeyColumn: String { get }
    static var columns: [String] { get }

    var id: ID { get }

    init(
        databaseRow: DatabaseRow
    ) throws

    func databaseValues() throws
        -> [String: DatabaseValue]
}
