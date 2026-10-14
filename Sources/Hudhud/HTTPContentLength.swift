import NIOHTTP1

internal enum HTTPContentLength {
    @inline(__always)
    static func declaredExceedsLimit(
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
    static func exceedsLimit(
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
