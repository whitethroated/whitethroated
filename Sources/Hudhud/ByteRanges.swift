import NIOCore
import NIOHTTP1

public enum ByteRangeResult: Sendable, Equatable {
    case none
    case satisfiable(Range<Int>)
    case unsatisfiable
    case malformed
    case unsupportedMultiple
    case unsupportedUnit
}

internal enum ByteRangeParser {
    static func parse(
        headers: HTTPHeaders,
        totalLength: Int
    ) -> ByteRangeResult {
        precondition(
            totalLength >= 0,
            "totalLength must be zero or greater"
        )

        let values = headers[
            canonicalForm: "range"
        ]

        guard !values.isEmpty else {
            return .none
        }

        guard values.count == 1 else {
            return .unsupportedMultiple
        }

        return parseValue(
            values[0].utf8,
            totalLength: totalLength
        )
    }

    private static func parseValue<
        C: BidirectionalCollection
    >(
        _ bytes: C,
        totalLength: Int
    ) -> ByteRangeResult
    where C.Element == UInt8 {
        var cursor = bytes.startIndex

        skipOWS(
            bytes,
            cursor: &cursor
        )

        guard consumeBytesUnit(
            bytes,
            cursor: &cursor
        ) else {
            return .unsupportedUnit
        }

        skipOWS(
            bytes,
            cursor: &cursor
        )

        guard
            cursor != bytes.endIndex,
            bytes[cursor] == 61
        else {
            return .malformed
        }

        bytes.formIndex(after: &cursor)

        skipOWS(
            bytes,
            cursor: &cursor
        )

        guard cursor != bytes.endIndex else {
            return .malformed
        }

        var end = bytes.endIndex

        while end != cursor {
            let previous = bytes.index(before: end)
            let byte = bytes[previous]

            guard byte == 32 || byte == 9 else {
                break
            }

            end = previous
        }

        guard cursor != end else {
            return .malformed
        }

        var scan = cursor

        while scan != end {
            if bytes[scan] == 44 {
                return .unsupportedMultiple
            }

            bytes.formIndex(after: &scan)
        }

        var hyphen: C.Index?
        scan = cursor

        while scan != end {
            if bytes[scan] == 45 {
                guard hyphen == nil else {
                    return .malformed
                }

                hyphen = scan
            }

            bytes.formIndex(after: &scan)
        }

        guard let hyphen else {
            return .malformed
        }

        let afterHyphen = bytes.index(
            after: hyphen
        )

        if hyphen == cursor {
            guard
                let suffixLength = parseDecimal(
                    bytes[afterHyphen..<end]
                ),
                suffixLength > 0
            else {
                return .malformed
            }

            guard totalLength > 0 else {
                return .unsatisfiable
            }

            let length = min(
                suffixLength,
                totalLength
            )

            return .satisfiable(
                (totalLength - length)..<totalLength
            )
        }

        guard let first = parseDecimal(
            bytes[cursor..<hyphen]
        ) else {
            return .malformed
        }

        guard first < totalLength else {
            return .unsatisfiable
        }

        if afterHyphen == end {
            return .satisfiable(
                first..<totalLength
            )
        }

        guard let last = parseDecimal(
            bytes[afterHyphen..<end]
        ) else {
            return .malformed
        }

        guard last >= first else {
            return .malformed
        }

        let cappedLast = min(
            last,
            totalLength - 1
        )

        return .satisfiable(
            first..<(cappedLast + 1)
        )
    }

    private static func consumeBytesUnit<
        C: Collection
    >(
        _ bytes: C,
        cursor: inout C.Index
    ) -> Bool
    where C.Element == UInt8 {
        let expected: [UInt8] = [
            98,
            121,
            116,
            101,
            115
        ]

        for expectedByte in expected {
            guard cursor != bytes.endIndex else {
                return false
            }

            let byte = bytes[cursor]
            let folded =
                byte >= 65 && byte <= 90
                ? byte + 32
                : byte

            guard folded == expectedByte else {
                return false
            }

            bytes.formIndex(after: &cursor)
        }

        return true
    }

    private static func skipOWS<
        C: Collection
    >(
        _ bytes: C,
        cursor: inout C.Index
    )
    where C.Element == UInt8 {
        while cursor != bytes.endIndex {
            let byte = bytes[cursor]

            guard byte == 32 || byte == 9 else {
                return
            }

            bytes.formIndex(after: &cursor)
        }
    }

    private static func parseDecimal<
        C: Collection
    >(
        _ bytes: C
    ) -> Int?
    where C.Element == UInt8 {
        guard !bytes.isEmpty else {
            return nil
        }

        var value = 0

        for byte in bytes {
            guard byte >= 48 && byte <= 57 else {
                return nil
            }

            let digit = Int(byte - 48)

            guard
                value <= (Int.max - digit) / 10
            else {
                return nil
            }

            value =
                value * 10
                + digit
        }

        return value
    }
}

extension Request {
    public func byteRange(
        totalLength: Int
    ) -> ByteRangeResult {
        ByteRangeParser.parse(
            headers: headers,
            totalLength: totalLength
        )
    }
}

extension StreamRequest {
    public func byteRange(
        totalLength: Int
    ) -> ByteRangeResult {
        ByteRangeParser.parse(
            headers: headers,
            totalLength: totalLength
        )
    }
}

extension Response {
    public static func partialFileRegion(
        _ value: FileRegion,
        range: Range<Int>,
        contentType: String? = nil
    ) -> Response {
        precondition(
            range.lowerBound >= 0,
            "range lower bound must be zero or greater"
        )
        precondition(
            !range.isEmpty,
            "range must contain at least one byte"
        )
        precondition(
            range.upperBound <= value.readableBytes,
            "range exceeds the readable file region"
        )

        let totalLength = value.readableBytes
        let baseOffset = value.readerIndex
        let region = FileRegion(
            fileHandle: value.fileHandle,
            readerIndex:
                baseOffset + range.lowerBound,
            endIndex:
                baseOffset + range.upperBound
        )

        var response = Response.fileRegion(
            region,
            contentType: contentType,
            status: .partialContent
        )
        response.headers.add(
            name: "accept-ranges",
            value: "bytes"
        )
        response.headers.add(
            name: "content-range",
            value:
                "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalLength)"
        )

        return response
    }

    public static func rangeNotSatisfiable(
        totalLength: Int
    ) -> Response {
        precondition(
            totalLength >= 0,
            "totalLength must be zero or greater"
        )

        var headers = HTTPHeaders()
        headers.add(
            name: "accept-ranges",
            value: "bytes"
        )
        headers.add(
            name: "content-range",
            value: "bytes */\(totalLength)"
        )

        return Response(
            status: .rangeNotSatisfiable,
            headers: headers,
            body: .empty
        )
    }

    public func acceptingByteRanges() -> Response {
        header(
            "accept-ranges",
            "bytes"
        )
    }
}
