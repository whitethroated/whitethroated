import Foundation

/// A database scalar value independent of a concrete driver.
///
/// The initial contract intentionally supports a small, portable set of
/// scalar types. Adapters map other driver-specific types to bytes so callers
/// can opt into a specialized decoder without weakening the common contract.
public enum DatabaseValue:
    Sendable,
    Hashable
{
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case uuid(UUID)
    case bytes([UInt8])

    public var isNull: Bool {
        if case .null = self {
            return true
        }

        return false
    }

    public var typeName: String {
        switch self {
        case .null:
            return "null"
        case .bool:
            return "bool"
        case .int:
            return "int"
        case .double:
            return "double"
        case .string:
            return "string"
        case .uuid:
            return "uuid"
        case .bytes:
            return "bytes"
        }
    }
}

public enum DatabaseValueError:
    Error,
    Sendable,
    Equatable
{
    case typeMismatch(
        expected: String,
        actual: String
    )
    case outOfRange(
        expected: String,
        actual: String
    )
    case invalidValue(
        expected: String,
        actual: String
    )
}

/// A Swift type that can cross the database value boundary.
public protocol DatabaseValueConvertible:
    Sendable
{
    var databaseValue: DatabaseValue { get }

    static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> Self
}

extension Bool: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        .bool(self)
    }

    public static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> Bool {
        guard case .bool(let bool) = value else {
            throw DatabaseValueError.typeMismatch(
                expected: "bool",
                actual: value.typeName
            )
        }

        return bool
    }
}

extension Int64: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        .int(self)
    }

    public static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> Int64 {
        guard case .int(let int) = value else {
            throw DatabaseValueError.typeMismatch(
                expected: "int",
                actual: value.typeName
            )
        }

        return int
    }
}

extension Int: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        .int(Int64(self))
    }

    public static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> Int {
        let int = try Int64.decodeDatabaseValue(value)

        guard let converted = Int(exactly: int) else {
            throw DatabaseValueError.outOfRange(
                expected: "Int",
                actual: "\(int)"
            )
        }

        return converted
    }
}

extension Double: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        .double(self)
    }

    public static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> Double {
        guard case .double(let double) = value else {
            throw DatabaseValueError.typeMismatch(
                expected: "double",
                actual: value.typeName
            )
        }

        return double
    }
}

extension String: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        .string(self)
    }

    public static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> String {
        guard case .string(let string) = value else {
            throw DatabaseValueError.typeMismatch(
                expected: "string",
                actual: value.typeName
            )
        }

        return string
    }
}

extension Array: DatabaseValueConvertible
where Element == UInt8 {
    public var databaseValue: DatabaseValue {
        .bytes(self)
    }

    public static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> [UInt8] {
        guard case .bytes(let bytes) = value else {
            throw DatabaseValueError.typeMismatch(
                expected: "bytes",
                actual: value.typeName
            )
        }

        return bytes
    }
}

extension UUID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        .uuid(self)
    }

    public static func decodeDatabaseValue(
        _ value: DatabaseValue
    ) throws -> UUID {
        switch value {
        case .uuid(let uuid):
            return uuid
        case .string(let string):
            guard let uuid = UUID(uuidString: string) else {
                throw DatabaseValueError.invalidValue(
                    expected: "UUID",
                    actual: string
                )
            }

            return uuid
        default:
            throw DatabaseValueError.typeMismatch(
                expected: "uuid",
                actual: value.typeName
            )
        }
    }
}
