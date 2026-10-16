enum URLComponentDecoder {
    private static let percent: UInt8 = 37
    private static let plus: UInt8 = 43
    private static let space: UInt8 = 32

    static func decode<C: Collection>(
        _ bytes: C,
        plusAsSpace: Bool
    ) -> String where C.Element == UInt8 {
        var requiresDecoding = false

        for byte in bytes {
            if
                byte == percent
                || (plusAsSpace && byte == plus)
            {
                requiresDecoding = true
                break
            }
        }

        guard requiresDecoding else {
            return String(
                decoding: bytes,
                as: UTF8.self
            )
        }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.underestimatedCount)

        var index = bytes.startIndex

        while index != bytes.endIndex {
            let byte = bytes[index]

            if plusAsSpace && byte == plus {
                output.append(space)
                bytes.formIndex(after: &index)
                continue
            }

            if byte == percent {
                let first = bytes.index(after: index)

                if first != bytes.endIndex {
                    let second = bytes.index(after: first)

                    if
                        second != bytes.endIndex,
                        let high = hexValue(bytes[first]),
                        let low = hexValue(bytes[second])
                    {
                        output.append(
                            (high << 4) | low
                        )
                        index = bytes.index(after: second)
                        continue
                    }
                }
            }

            output.append(byte)
            bytes.formIndex(after: &index)
        }

        return String(
            decoding: output,
            as: UTF8.self
        )
    }

    static func equalsDecoded<C: Collection, D: Collection>(
        _ bytes: C,
        _ expected: D,
        plusAsSpace: Bool
    ) -> Bool
    where C.Element == UInt8, D.Element == UInt8 {
        var sourceIndex = bytes.startIndex
        var expectedIndex = expected.startIndex

        while sourceIndex != bytes.endIndex {
            guard expectedIndex != expected.endIndex else {
                return false
            }

            let sourceByte = bytes[sourceIndex]
            let decodedByte: UInt8

            if plusAsSpace && sourceByte == plus {
                decodedByte = space
                bytes.formIndex(after: &sourceIndex)
            } else if sourceByte == percent {
                let first = bytes.index(after: sourceIndex)

                if first != bytes.endIndex {
                    let second = bytes.index(after: first)

                    if
                        second != bytes.endIndex,
                        let high = hexValue(bytes[first]),
                        let low = hexValue(bytes[second])
                    {
                        decodedByte = (high << 4) | low
                        sourceIndex = bytes.index(after: second)
                    } else {
                        decodedByte = sourceByte
                        bytes.formIndex(after: &sourceIndex)
                    }
                } else {
                    decodedByte = sourceByte
                    bytes.formIndex(after: &sourceIndex)
                }
            } else {
                decodedByte = sourceByte
                bytes.formIndex(after: &sourceIndex)
            }

            guard decodedByte == expected[expectedIndex] else {
                return false
            }

            expected.formIndex(after: &expectedIndex)
        }

        return expectedIndex == expected.endIndex
    }

    @inline(__always)
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
}
