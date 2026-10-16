internal enum ContentDisposition {
    static func attachment(
        filename: String
    ) -> String {
        let fallback = quotedFallback(
            filename
        )

        guard !filename.utf8.allSatisfy({
            $0 >= 32 && $0 < 127
        }) else {
            return "attachment; filename=\"" + fallback + "\""
        }

        return "attachment; filename=\"" + fallback
            + "\"; filename*=UTF-8''"
            + encodedExtendedValue(filename)
    }

    private static func quotedFallback(
        _ filename: String
    ) -> String {
        var result = ""
        result.reserveCapacity(
            filename.utf8.count
        )

        for byte in filename.utf8 {
            switch byte {
            case 32...126:
                if byte == 34 || byte == 92 {
                    result.append("\\")
                }

                result.append(
                    asciiCharacter(byte)
                )

            default:
                result.append("_")
            }
        }

        return result.isEmpty
            ? "download"
            : result
    }

    private static func encodedExtendedValue(
        _ filename: String
    ) -> String {
        var result = ""
        result.reserveCapacity(
            filename.utf8.count * 3
        )

        for byte in filename.utf8 {
            if isRFC5987AttributeByte(byte) {
                result.append(
                    asciiCharacter(byte)
                )
                continue
            }

            result.append("%")
            result.append(
                hexDigit(byte >> 4)
            )
            result.append(
                hexDigit(byte & 0x0F)
            )
        }

        return result
    }

    @inline(__always)
    private static func isRFC5987AttributeByte(
        _ byte: UInt8
    ) -> Bool {
        switch byte {
        case 48...57,
             65...90,
             97...122,
             33,
             35...36,
             38,
             43...46,
             94...96,
             124,
             126:
            return true

        default:
            return false
        }
    }

    @inline(__always)
    private static func asciiCharacter(
        _ byte: UInt8
    ) -> Character {
        Character(
            UnicodeScalar(Int(byte))!
        )
    }

    @inline(__always)
    private static func hexDigit(
        _ value: UInt8
    ) -> Character {
        let byte =
            value < 10
            ? 48 + value
            : 55 + value

        return asciiCharacter(byte)
    }
}

extension Response {
    public mutating func setAttachment(
        _ filename: String
    ) {
        headers.replaceOrAdd(
            name: "content-disposition",
            value: ContentDisposition.attachment(
                filename: filename
            )
        )
    }

    public func attachment(
        _ filename: String
    ) -> Response {
        var copy = self
        copy.setAttachment(filename)
        return copy
    }
}
