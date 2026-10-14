import NIOHTTP1

public struct EntityTag: Sendable, Equatable, Hashable {
    public let opaqueValue: String
    public let isWeak: Bool

    public init(
        _ opaqueValue: String,
        weak: Bool = false
    ) {
        precondition(
            Self.isValidOpaqueValue(
                opaqueValue
            ),
            "ETag value contains invalid characters"
        )

        self.opaqueValue = opaqueValue
        self.isWeak = weak
    }

    public static func weak(
        _ opaqueValue: String
    ) -> EntityTag {
        EntityTag(
            opaqueValue,
            weak: true
        )
    }

    public var headerValue: String {
        if isWeak {
            return "W/\"" + opaqueValue + "\""
        }

        return "\"" + opaqueValue + "\""
    }

    private static func isValidOpaqueValue(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        for byte in value.utf8 {
            switch byte {
            case 33,
                 35...126:
                continue

            default:
                return false
            }
        }

        return true
    }
}

internal enum IfNoneMatchMatcher {
    static func matches(
        headers: HTTPHeaders,
        tag: EntityTag
    ) -> Bool {
        let expected = tag.opaqueValue.utf8

        for (name, value) in headers {
            guard isIfNoneMatchHeader(name) else {
                continue
            }

            if matches(
                value.utf8,
                expected: expected
            ) {
                return true
            }
        }

        return false
    }

    @inline(__always)
    private static func isIfNoneMatchHeader(
        _ name: String
    ) -> Bool {
        let expected: [UInt8] = [
            105, 102, 45, 110, 111, 110, 101,
            45, 109, 97, 116, 99, 104
        ]
        let bytes = name.utf8

        guard bytes.count == expected.count else {
            return false
        }

        var index = bytes.startIndex

        for expectedByte in expected {
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

    private static func matches<
        C: Collection,
        E: Collection
    >(
        _ bytes: C,
        expected: E
    ) -> Bool
    where
        C.Element == UInt8,
        E.Element == UInt8
    {
        var cursor = bytes.startIndex

        while true {
            skipOWS(
                bytes,
                cursor: &cursor
            )

            guard cursor != bytes.endIndex else {
                return false
            }

            if bytes[cursor] == 42 {
                bytes.formIndex(after: &cursor)
                skipOWS(
                    bytes,
                    cursor: &cursor
                )

                if
                    cursor == bytes.endIndex
                    || bytes[cursor] == 44
                {
                    return true
                }

                return false
            }

            if bytes[cursor] == 87 {
                let afterW = bytes.index(
                    after: cursor
                )

                guard
                    afterW != bytes.endIndex,
                    bytes[afterW] == 47
                else {
                    return false
                }

                cursor = bytes.index(
                    after: afterW
                )
            }

            guard
                cursor != bytes.endIndex,
                bytes[cursor] == 34
            else {
                return false
            }

            bytes.formIndex(after: &cursor)
            let opaqueStart = cursor

            while
                cursor != bytes.endIndex,
                bytes[cursor] != 34
            {
                guard isEntityTagByte(
                    bytes[cursor]
                ) else {
                    return false
                }

                bytes.formIndex(after: &cursor)
            }

            guard cursor != bytes.endIndex else {
                return false
            }

            let opaqueEnd = cursor
            bytes.formIndex(after: &cursor)

            let matched = equals(
                bytes[opaqueStart..<opaqueEnd],
                expected
            )

            skipOWS(
                bytes,
                cursor: &cursor
            )

            if cursor == bytes.endIndex {
                return matched
            }

            guard bytes[cursor] == 44 else {
                return false
            }

            if matched {
                return true
            }

            bytes.formIndex(after: &cursor)
        }
    }

    @inline(__always)
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

    @inline(__always)
    private static func isEntityTagByte(
        _ byte: UInt8
    ) -> Bool {
        byte == 33
            || (byte >= 35 && byte <= 126)
            || byte >= 128
    }

    @inline(__always)
    private static func equals<
        L: Collection,
        R: Collection
    >(
        _ lhs: L,
        _ rhs: R
    ) -> Bool
    where
        L.Element == UInt8,
        R.Element == UInt8
    {
        guard lhs.count == rhs.count else {
            return false
        }

        var left = lhs.startIndex
        var right = rhs.startIndex

        while left != lhs.endIndex {
            if lhs[left] != rhs[right] {
                return false
            }

            lhs.formIndex(after: &left)
            rhs.formIndex(after: &right)
        }

        return true
    }
}

extension Request {
    public func matchesIfNoneMatch(
        _ tag: EntityTag
    ) -> Bool {
        IfNoneMatchMatcher.matches(
            headers: headers,
            tag: tag
        )
    }
}

extension StreamRequest {
    public func matchesIfNoneMatch(
        _ tag: EntityTag
    ) -> Bool {
        IfNoneMatchMatcher.matches(
            headers: headers,
            tag: tag
        )
    }
}

extension Response {
    public mutating func setETag(
        _ tag: EntityTag
    ) {
        headers.replaceOrAdd(
            name: "etag",
            value: tag.headerValue
        )
    }

    public func etag(
        _ tag: EntityTag
    ) -> Response {
        var copy = self
        copy.setETag(tag)
        return copy
    }

    public static func notModified(
        etag: EntityTag? = nil
    ) -> Response {
        var response = Response(
            status: .notModified
        )

        if let etag {
            response.setETag(etag)
        }

        return response
    }
}
