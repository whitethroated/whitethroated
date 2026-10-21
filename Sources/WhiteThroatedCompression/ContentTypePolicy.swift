/// Content-type allow policy for buffered compression.
///
/// Matching is ASCII case-insensitive, ignores media-type
/// parameters, and never allocates on the request path. Responses
/// without a `content-type` header are not compressible.
public struct ContentTypePolicy: Sendable {
    internal enum Pattern: Sendable, Equatable {
        case any
        case type([UInt8])
        case exact([UInt8])
    }

    /// Compresses the common text and structured-data types. Already
    /// compressed binary formats are intentionally absent and must be
    /// opted into explicitly.
    public static let `default`: ContentTypePolicy =
        ContentTypePolicy(
            patterns: [
                "text/*",
                "application/json",
                "application/ld+json",
                "application/manifest+json",
                "application/javascript",
                "text/javascript",
                "application/xml",
                "application/xhtml+xml",
                "application/rss+xml",
                "application/atom+xml",
                "image/svg+xml",
                "application/wasm",
            ].compactMap(Self.pattern)
        )

    /// Compresses every response with a content type.
    public static let allowAll: ContentTypePolicy =
        ContentTypePolicy(
            patterns: [.any]
        )

    /// Compresses exactly the listed media types. Entries may be
    /// exact media types (`application/json`) or type wildcards
    /// (`text/*`). An empty set compresses nothing.
    public static func only(
        _ contentTypes: Set<String>
    ) -> ContentTypePolicy {
        ContentTypePolicy(
            patterns: contentTypes
                .compactMap(Self.pattern)
        )
    }

    internal let patterns: [Pattern]

    internal init(
        patterns: [Pattern]
    ) {
        self.patterns = patterns
    }

    internal func allows(
        _ contentType: String
    ) -> Bool {
        guard !patterns.isEmpty else {
            return false
        }

        let mediaType =
            Self.mediaTypeRange(
                of: contentType
            )

        guard !mediaType.isEmpty else {
            return false
        }

        for pattern in patterns {
            switch pattern {
            case .any:
                return true

            case .type(let type):
                if Self.matchesType(
                    type,
                    mediaType: mediaType
                ) {
                    return true
                }

            case .exact(let expected):
                if asciiEquals(
                    mediaType.utf8,
                    expected
                ) {
                    return true
                }
            }
        }

        return false
    }

    private static func pattern(
        _ value: String
    ) -> Pattern? {
        let mediaType =
            mediaTypeRange(of: value)

        guard !mediaType.isEmpty else {
            return nil
        }

        if mediaType == "*" {
            return .any
        }

        if mediaType.hasSuffix("/*") {
            let type = mediaType.dropLast(2)

            guard
                !type.isEmpty,
                !type.contains("*")
            else {
                return nil
            }

            return .type(
                Array(
                    type
                        .lowercased()
                        .utf8
                )
            )
        }

        guard !mediaType.contains("*") else {
            return nil
        }

        return .exact(
            Array(
                mediaType
                    .lowercased()
                    .utf8
            )
        )
    }

    private static func matchesType(
        _ type: [UInt8],
        mediaType: Substring
    ) -> Bool {
        let bytes = mediaType.utf8

        guard bytes.count > type.count + 1 else {
            return false
        }

        var typeIndex = type.startIndex
        var byteIndex = bytes.startIndex

        while typeIndex != type.endIndex {
            guard
                asciiFolded(bytes[byteIndex])
                    == asciiFolded(type[typeIndex])
            else {
                return false
            }

            type.formIndex(
                after: &typeIndex
            )
            bytes.formIndex(
                after: &byteIndex
            )
        }

        return bytes[byteIndex] == 47
    }

    private static func mediaTypeRange(
        of value: String
    ) -> Substring {
        let beforeParameters =
            value.prefix { $0 != ";" }

        var start =
            beforeParameters.startIndex
        var end =
            beforeParameters.endIndex

        while
            start < end,
            Self.isOptionalMediaWhitespace(
                beforeParameters[start]
            )
        {
            start =
                beforeParameters.index(
                    after: start
                )
        }

        while end > start {
            let previous =
                beforeParameters.index(
                    before: end
                )

            guard
                Self.isOptionalMediaWhitespace(
                    beforeParameters[previous]
                )
            else {
                break
            }

            end = previous
        }

        return beforeParameters[start..<end]
    }

    private static func isOptionalMediaWhitespace(
        _ character: Character
    ) -> Bool {
        character == " " || character == "\t"
    }
}
