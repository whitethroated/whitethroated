import NIOHTTP1

public enum HTTPContentLength {
    private static let contentLengthNameBytes: [UInt8] = [
        99, 111, 110, 116, 101, 110, 116,
        45, 108, 101, 110, 103, 116, 104
    ]

    private static let transferEncodingNameBytes: [UInt8] = [
        116, 114, 97, 110, 115, 102, 101, 114,
        45, 101, 110, 99, 111, 100, 105, 110, 103
    ]

    @inline(__always)
    public static func declaredExceedsLimit(
        _ headers: HTTPHeaders,
        limit: Int
    ) -> Bool {
        guard let value = headers.first(
            name: "content-length"
        ) else {
            return false
        }

        return exceedsLimit(
            value,
            limit: limit
        )
    }

    @inline(__always)
    public static func hasSingleExactValue(
        _ headers: HTTPHeaders,
        value: String
    ) -> Bool {
        var found = false

        for (name, candidate) in headers {
            guard isContentLengthName(name) else {
                continue
            }

            guard
                !found,
                candidate == value
            else {
                return false
            }

            found = true
        }

        return found
    }

    @inline(__always)
    public static func isContentLengthName(
        _ name: String
    ) -> Bool {
        isName(
            name,
            equalTo: contentLengthNameBytes
        )
    }

    @inline(__always)
    public static func isTransferEncodingName(
        _ name: String
    ) -> Bool {
        isName(
            name,
            equalTo: transferEncodingNameBytes
        )
    }

    @inline(__always)
    public static func isFramingName(
        _ name: String
    ) -> Bool {
        isContentLengthName(name)
            || isTransferEncodingName(name)
    }

    @inline(__always)
    private static func isName(
        _ name: String,
        equalTo expectedBytes: [UInt8]
    ) -> Bool {
        let bytes = name.utf8

        guard
            bytes.count
                == expectedBytes.count
        else {
            return false
        }

        var index = bytes.startIndex

        for expectedByte in expectedBytes {
            let byte = bytes[index]
            let folded =
                byte >= 65 && byte <= 90
                ? byte + 32
                : byte

            guard folded == expectedByte else {
                return false
            }

            bytes.formIndex(after: &index)
        }

        return true
    }

    @inline(__always)
    public static func exceedsLimit(
        _ value: String,
        limit: Int
    ) -> Bool {
        precondition(
            limit >= 0,
            "Content-Length limit must be zero or greater"
        )

        let bytes = value.utf8
        var cursor = bytes.startIndex
        var parsed = 0
        var exceeded = false
        var sawDigit = false

        while cursor != bytes.endIndex {
            let byte = bytes[cursor]

            if byte == 32 || byte == 9 {
                bytes.formIndex(after: &cursor)
                continue
            }

            break
        }

        while cursor != bytes.endIndex {
            let byte = bytes[cursor]

            guard byte >= 48 && byte <= 57 else {
                break
            }

            sawDigit = true
            let digit = Int(byte - 48)

            if !exceeded {
                let quotient = limit / 10
                let remainder = limit % 10

                if
                    parsed > quotient
                    || (
                        parsed == quotient
                        && digit > remainder
                    )
                {
                    exceeded = true
                } else {
                    parsed =
                        parsed * 10
                        + digit
                }
            }

            bytes.formIndex(after: &cursor)
        }

        guard sawDigit else {
            return false
        }

        while cursor != bytes.endIndex {
            let byte = bytes[cursor]

            guard byte == 32 || byte == 9 else {
                return false
            }

            bytes.formIndex(after: &cursor)
        }

        return exceeded
    }
}
