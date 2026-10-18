/// Byte-level validation mirroring SwiftNIO's outbound HTTP rules.
///
/// Faithful port of the pinned SwiftNIO 2.104.0 validation semantics
/// (`HTTPHeaders+Validation.swift`, `HTTPHeaderValidator.swift`):
/// header names are `token`, header values reject every ASCII control
/// except HTAB, and custom reason phrases allow HTAB/SP/VCHAR/obs-text.
///
/// Two deliberate NIO-equivalence notes, both locked by tests:
/// - Empty names/values/reasons pass (NIO's `allSatisfy` over an empty
///   view is vacuously true). This mirrors NIO rather than improving it
///   so the experimental writer stays semantically identical.
/// - Custom status codes are validated by reason bytes only; the numeric
///   code itself is never range-checked, exactly like NIO.
public enum WTHTTP1Validation {
    @inline(__always)
    public static func isValidHeaderNameByte(
        _ byte: UInt8
    ) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "!"),
            UInt8(ascii: "#"),
            UInt8(ascii: "$"),
            UInt8(ascii: "%"),
            UInt8(ascii: "&"),
            UInt8(ascii: "'"),
            UInt8(ascii: "*"),
            UInt8(ascii: "+"),
            UInt8(ascii: "-"),
            UInt8(ascii: "."),
            UInt8(ascii: "^"),
            UInt8(ascii: "_"),
            UInt8(ascii: "`"),
            UInt8(ascii: "|"),
            UInt8(ascii: "~"):
            return true

        default:
            return false
        }
    }

    @inline(__always)
    public static func isValidHeaderValueByte(
        _ byte: UInt8
    ) -> Bool {
        switch byte {
        case UInt8(ascii: "\t"):
            return true

        case 0...0x1f, 0x7f:
            return false

        default:
            return true
        }
    }

    @inline(__always)
    public static func isValidReasonPhraseByte(
        _ byte: UInt8
    ) -> Bool {
        switch byte {
        case 9, 32, 33...126, 128...255:
            return true

        default:
            return false
        }
    }

    public static func isValidHeaderName<S: Sequence>(
        _ bytes: S
    ) -> Bool where S.Element == UInt8 {
        bytes.allSatisfy(isValidHeaderNameByte)
    }

    public static func isValidHeaderValue<S: Sequence>(
        _ bytes: S
    ) -> Bool where S.Element == UInt8 {
        bytes.allSatisfy(isValidHeaderValueByte)
    }

    public static func isValidReasonPhrase<S: Sequence>(
        _ bytes: S
    ) -> Bool where S.Element == UInt8 {
        bytes.allSatisfy(isValidReasonPhraseByte)
    }
}
