import CPostgres
import Foundation
import WhiteThroatedDatabase

struct PostgresParameter:
    Sendable
{
    let text: String?
    let type: Oid
}

enum PostgresValueCodec {
    static func parameter(
        _ value: DatabaseValue
    ) throws -> PostgresParameter {
        switch value {
        case .null:
            return PostgresParameter(
                text: nil,
                type: 0
            )

        case .bool(let bool):
            return PostgresParameter(
                text: bool ? "true" : "false",
                type: 16
            )

        case .int(let int):
            return PostgresParameter(
                text: String(int),
                type: 20
            )

        case .double(let double):
            return PostgresParameter(
                text: doubleText(double),
                type: 701
            )

        case .string(let string):
            guard !string.utf8.contains(0) else {
                throw PostgresErrorMapper.mapping(
                    "String bindings must not contain a NUL byte"
                )
            }

            // Leave text parameters unspecified so PostgreSQL can infer the
            // column or operator type. This avoids rejecting text bindings for
            // uuid, enum, and other assignment-cast targets.
            return PostgresParameter(
                text: string,
                type: 0
            )

        case .uuid(let uuid):
            return PostgresParameter(
                text: uuid.uuidString,
                type: 2950
            )

        case .bytes(let bytes):
            return PostgresParameter(
                text: PostgresBytes.encodeHex(
                    bytes
                ),
                type: 17
            )
        }
    }

    static func value(
        type: Oid,
        bytes: UnsafeBufferPointer<UInt8>
    ) throws -> DatabaseValue {
        switch type {
        case 16:
            guard let text = String(
                bytes: bytes,
                encoding: .utf8
            ) else {
                throw invalidUTF8(type)
            }

            switch text {
            case "t", "true", "1":
                return .bool(true)
            case "f", "false", "0":
                return .bool(false)
            default:
                throw PostgresErrorMapper.mapping(
                    "Invalid boolean value from PostgreSQL"
                )
            }

        case 20, 21, 23, 26:
            guard
                let text = String(
                    bytes: bytes,
                    encoding: .utf8
                ),
                let int = Int64(text)
            else {
                throw PostgresErrorMapper.mapping(
                    "Invalid integer value from PostgreSQL"
                )
            }

            return .int(int)

        case 700, 701:
            guard
                let text = String(
                    bytes: bytes,
                    encoding: .utf8
                ),
                let double = Double(text)
            else {
                throw PostgresErrorMapper.mapping(
                    "Invalid floating-point value from PostgreSQL"
                )
            }

            return .double(double)

        case 17:
            return .bytes(
                try PostgresBytes.decodeBytea(
                    bytes
                )
            )

        case 2950:
            guard
                let text = String(
                    bytes: bytes,
                    encoding: .utf8
                ),
                let uuid = UUID(
                    uuidString: text
                )
            else {
                throw PostgresErrorMapper.mapping(
                    "Invalid uuid value from PostgreSQL"
                )
            }

            return .uuid(uuid)

        default:
            guard let text = String(
                bytes: bytes,
                encoding: .utf8
            ) else {
                throw invalidUTF8(type)
            }

            // numeric, date/time, json, arrays, and unknown extension types
            // retain their text representation. This avoids silent precision
            // loss for numeric values and keeps adapter semantics predictable.
            return .string(text)
        }
    }

    private static func invalidUTF8(
        _ type: Oid
    ) -> DatabaseError {
        PostgresErrorMapper.mapping(
            "PostgreSQL value with OID \(type) is not valid UTF-8; set the connection client encoding to UTF8"
        )
    }

    private static func doubleText(
        _ double: Double
    ) -> String {
        if double.isNaN {
            return "NaN"
        }

        if double.isInfinite {
            return double.sign == .minus
                ? "-Infinity"
                : "Infinity"
        }

        return String(double)
    }
}

enum PostgresBytes {
    static func encodeHex(
        _ bytes: [UInt8]
    ) -> String {
        var output =
            "\\x"
        output.reserveCapacity(
            2 + bytes.count * 2
        )

        let digits =
            Array("0123456789abcdef".utf8)

        for byte in bytes {
            output.append(
                Character(
                    UnicodeScalar(
                        digits[Int(byte >> 4)]
                    )
                )
            )
            output.append(
                Character(
                    UnicodeScalar(
                        digits[Int(byte & 0x0F)]
                    )
                )
            )
        }

        return output
    }

    static func decodeBytea(
        _ bytes: UnsafeBufferPointer<UInt8>
    ) throws -> [UInt8] {
        if bytes.count >= 2,
           bytes[0] == 92,
           bytes[1] == 120
        {
            return try decodeHex(
                bytes,
                from: 2
            )
        }

        return try decodeEscape(
            bytes
        )
    }

    private static func decodeHex(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int
    ) throws -> [UInt8] {
        let hexCount =
            bytes.count - start

        guard hexCount % 2 == 0 else {
            throw PostgresErrorMapper.mapping(
                "Invalid bytea hex value from PostgreSQL"
            )
        }

        var output:
            [UInt8] = []
        output.reserveCapacity(
            hexCount / 2
        )
        var index = start

        while index < bytes.count {
            guard
                let high = hexValue(
                    bytes[index]
                ),
                let low = hexValue(
                    bytes[index + 1]
                )
            else {
                throw PostgresErrorMapper.mapping(
                    "Invalid bytea hex value from PostgreSQL"
                )
            }

            output.append(
                (high << 4) | low
            )
            index += 2
        }

        return output
    }

    private static func decodeEscape(
        _ bytes: UnsafeBufferPointer<UInt8>
    ) throws -> [UInt8] {
        var output:
            [UInt8] = []
        output.reserveCapacity(
            bytes.count
        )
        var index = 0

        while index < bytes.count {
            let byte =
                bytes[index]

            guard byte == 92 else {
                output.append(byte)
                index += 1
                continue
            }

            guard index + 1 < bytes.count else {
                throw PostgresErrorMapper.mapping(
                    "Invalid bytea escape value from PostgreSQL"
                )
            }

            if bytes[index + 1] == 92 {
                output.append(92)
                index += 2
                continue
            }

            guard
                index + 3 < bytes.count,
                let first = octalValue(
                    bytes[index + 1]
                ),
                let second = octalValue(
                    bytes[index + 2]
                ),
                let third = octalValue(
                    bytes[index + 3]
                )
            else {
                throw PostgresErrorMapper.mapping(
                    "Invalid bytea escape value from PostgreSQL"
                )
            }

            let value =
                (Int(first) << 6)
                    | (Int(second) << 3)
                    | Int(third)

            guard value <= 0xFF else {
                throw PostgresErrorMapper.mapping(
                    "Invalid bytea escape value from PostgreSQL"
                )
            }

            output.append(
                UInt8(value)
            )
            index += 4
        }

        return output
    }

    private static func hexValue(
        _ byte: UInt8
    ) -> UInt8? {
        switch byte {
        case 48...57:
            return byte - 48
        case 65...70:
            return byte - 55
        case 97...102:
            return byte - 87
        default:
            return nil
        }
    }

    private static func octalValue(
        _ byte: UInt8
    ) -> UInt8? {
        guard byte >= 48, byte <= 55 else {
            return nil
        }

        return byte - 48
    }
}
