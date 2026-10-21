import NIOCore
import NIOHTTP1
import WhiteThroated

/// Content codings supported by the compression module.
///
/// The raw value is the `Content-Encoding` token sent on the wire.
public enum CompressionAlgorithm: String, Sendable,
    CaseIterable
{
    case gzip
}

public enum CompressionError: Error, Equatable, Sendable {
    /// A precompressed representation was requested for a response
    /// carrying a strong entity tag. Compressed and identity
    /// representations need distinct strong validators.
    case conflictingETag

    /// zlib failed to produce an encoded representation during
    /// setup.
    case compressionFailed
}

/// Buffered HTTP compression for WhiteThroated applications.
///
/// The module never activates implicitly:
///
/// - `middleware()` is installed with `app.use(compression:)` and
///   compresses immediate and future responses whose bodies are
///   fully buffered;
/// - `encode(_:for:)` compresses a single response inside a handler;
/// - `precompressed(_:)` prepares encoded representations once at
///   setup and negotiates `Accept-Encoding` per request.
///
/// Prepared responses passed through installed middleware are never
/// rewritten. Streaming and file-region bodies are not compressed by
/// this module.
///
/// Compression is skipped when the response already carries a
/// content coding, a transfer coding, a content range, a strong
/// entity tag, an excluded content type, or a body below the
/// configured minimum. Eligible responses always carry
/// `Vary: Accept-Encoding`, whether or not a given request received
/// an encoded representation.
public struct Compression: Sendable {
    public struct Configuration: Sendable {
        /// Supported algorithms in server preference order. Equal
        /// client qualities select the earlier entry.
        public var algorithms: [CompressionAlgorithm]

        /// Bodies smaller than this are served identity.
        public var minimumBytes: Int

        /// zlib compression level (`-1` uses the library default,
        /// `0` disables compression, `1...9` raise compression).
        public var compressionLevel: Int

        /// Content types eligible for compression.
        public var contentTypes: ContentTypePolicy

        public init(
            algorithms: [CompressionAlgorithm] = [.gzip],
            minimumBytes: Int = 1024,
            compressionLevel: Int = 6,
            contentTypes: ContentTypePolicy = .default
        ) {
            precondition(
                !algorithms.isEmpty,
                "at least one compression algorithm is required"
            )
            precondition(
                minimumBytes >= 0,
                "minimumBytes must be zero or greater"
            )
            precondition(
                compressionLevel >= -1
                    && compressionLevel <= 9,
                "compressionLevel must be -1 or in 0...9"
            )

            self.algorithms = algorithms
            self.minimumBytes = minimumBytes
            self.compressionLevel = compressionLevel
            self.contentTypes = contentTypes
        }
    }

    public let configuration: Configuration

    internal let negotiator:
        AcceptEncodingNegotiator

    public init(
        configuration: Configuration = Configuration()
    ) {
        self.configuration = configuration
        self.negotiator = AcceptEncodingNegotiator(
            algorithms: configuration.algorithms
        )
    }

    /// Returns an encoded response when the request accepts a
    /// configured algorithm and the response is eligible.
    ///
    /// This API is opportunistic: ineligible responses and requests
    /// that cannot receive a configured coding are returned
    /// unchanged. The status is never rewritten. Use
    /// `precompressed(_:)` when strict negotiation is required.
    public func encode(
        _ response: Response,
        for request: Request
    ) -> Response {
        let analysis = analysis(of: response)

        guard case .eligible = analysis else {
            return response
        }

        return applying(
            negotiator.decide(
                headers: request.headers
            ),
            to: response
        )
    }

    /// Prepares encoded representations once at setup and returns a
    /// synchronous route handler that negotiates per request.
    ///
    /// An ineligible response falls back to a handler that always
    /// serves the identity representation. A response carrying a
    /// strong entity tag throws `CompressionError.conflictingETag`
    /// because strong validators must not be shared between
    /// representations. A weakly tagged response keeps its tag.
    ///
    /// A request that explicitly rejects identity and accepts no
    /// configured algorithm receives a `406 Not Acceptable`
    /// response.
    public func precompressed(
        _ response: Response
    ) throws -> SyncHandler {
        switch analysis(of: response) {
        case .ineligible:
            return { _ in
                response
            }

        case .strongETag:
            throw CompressionError
                .conflictingETag

        case .eligible:
            var identity = response

            Self.appendVary(
                to: &identity.headers
            )

            var variants: [Response] = []
            variants.reserveCapacity(
                configuration.algorithms.count
            )

            for algorithm in configuration
                .algorithms
            {
                guard
                    let compressed =
                        compressedBody(
                            of: response.body,
                            algorithm: algorithm
                        )
                else {
                    throw CompressionError
                        .compressionFailed
                }

                var variant = response
                variant.body = .buffer(compressed)

                variant.headers.replaceOrAdd(
                    name: "content-encoding",
                    value: algorithm.rawValue
                )
                variant.headers.replaceOrAdd(
                    name: "content-length",
                    value: String(
                        compressed.readableBytes
                    )
                )

                Self.appendVary(
                    to: &variant.headers
                )

                variants.append(variant)
            }

            var unacceptable = Response.text(
                "Not Acceptable",
                status: .notAcceptable
            )

            Self.appendVary(
                to: &unacceptable.headers
            )

            let precompressedVariants = variants
            let identityResponse = identity
            let notAcceptable = unacceptable
            let negotiator = self.negotiator

            return { request in
                switch negotiator.decide(
                    headers: request.headers
                ) {
                case .algorithm(let index):
                    return precompressedVariants[
                        index
                    ]

                case .identity:
                    return identityResponse

                case .notAcceptable:
                    return notAcceptable
                }
            }
        }
    }

    /// Fast middleware that compresses immediate and future
    /// responses.
    ///
    /// Prepared responses and response streams pass through
    /// untouched, so prepared routes keep the prepared writer path.
    /// Use `precompressed(_:)` to serve an encoded prepared payload.
    public func middleware() -> FastMiddleware {
        { request, _, next in
            let result = next(request)

            switch result {
            case .response(let response):
                return .response(
                    self.encode(
                        response,
                        for: request
                    )
                )

            case .prepared:
                return result

            case .future(let future):
                // The headers value is a cheap copy-on-write
                // reference; the request body is not retained until
                // the response future completes.
                let headers = request.headers

                return .future(
                    future.map { response in
                        let analysis =
                            self.analysis(
                                of: response
                            )

                        guard
                            case .eligible = analysis
                        else {
                            return response
                        }

                        return self.applying(
                            self.negotiator.decide(
                                headers: headers
                            ),
                            to: response
                        )
                    }
                )
            }
        }
    }

    // MARK: - Eligibility

    private enum Analysis {
        case ineligible
        case strongETag
        case eligible
    }

    private struct HeaderFacts {
        var hasContentEncoding = false
        var hasTransferEncoding = false
        var hasContentRange = false
        var hasStrongValidator = false
        var contentType: String?

        init(headers: HTTPHeaders) {
            var etagCount = 0
            var etagValue: String?

            for (name, value) in headers {
                if asciiEquals(
                    name.utf8,
                    Self.contentEncodingName
                ) {
                    hasContentEncoding = true
                } else if asciiEquals(
                    name.utf8,
                    Self.transferEncodingName
                ) {
                    hasTransferEncoding = true
                } else if asciiEquals(
                    name.utf8,
                    Self.contentRangeName
                ) {
                    hasContentRange = true
                } else if asciiEquals(
                    name.utf8,
                    Self.contentTypeName
                ) {
                    if contentType == nil {
                        contentType = value
                    }
                } else if asciiEquals(
                    name.utf8,
                    Self.etagName
                ) {
                    etagCount += 1

                    if etagValue == nil {
                        etagValue = value
                    }
                }
            }

            hasStrongValidator =
                Self.isStrongValidator(
                    count: etagCount,
                    value: etagValue
                )
        }

        private static let contentEncodingName:
            [UInt8] =
            Array("content-encoding".utf8)

        private static let transferEncodingName:
            [UInt8] =
            Array("transfer-encoding".utf8)

        private static let contentRangeName:
            [UInt8] =
            Array("content-range".utf8)

        private static let contentTypeName:
            [UInt8] =
            Array("content-type".utf8)

        private static let etagName: [UInt8] =
            Array("etag".utf8)

        /// Anything other than a single well-formed weak tag counts
        /// as a strong validator and blocks compression.
        private static func isStrongValidator(
            count: Int,
            value: String?
        ) -> Bool {
            guard count == 1, let value else {
                return count > 1
            }

            guard value.hasPrefix("W/") else {
                return true
            }

            let tag = value.dropFirst(2)

            return !(
                tag.hasPrefix("\"")
                    && tag.hasSuffix("\"")
                    && tag.count >= 2
                    && !value.contains(",")
            )
        }
    }

    private func analysis(
        of response: Response
    ) -> Analysis {
        guard response.status.mayHaveResponseBody
        else {
            return .ineligible
        }

        let length: Int

        switch response.body {
        case .text(let value):
            length = value.utf8.count

        case .bytes(let value):
            length = value.count

        case .buffer(let value):
            length = value.readableBytes

        case .empty, .fileRegion, .stream:
            return .ineligible
        }

        guard
            length > 0,
            length >= configuration.minimumBytes
        else {
            return .ineligible
        }

        let facts = HeaderFacts(
            headers: response.headers
        )

        guard
            !facts.hasContentEncoding,
            !facts.hasTransferEncoding,
            !facts.hasContentRange,
            response.status != .partialContent
        else {
            return .ineligible
        }

        guard
            let contentType = facts.contentType,
            configuration.contentTypes
                .allows(contentType)
        else {
            return .ineligible
        }

        if facts.hasStrongValidator {
            return .strongETag
        }

        return .eligible
    }

    // MARK: - Encoding

    /// Applies a negotiation decision. Callers only reach this after
    /// `analysis(of:)` returned `.eligible`.
    private func applying(
        _ decision:
            AcceptEncodingNegotiator.Decision,
        to response: Response
    ) -> Response {
        switch decision {
        case .algorithm(let index):
            let algorithm =
                configuration.algorithms[index]

            guard
                let compressed = compressedBody(
                    of: response.body,
                    algorithm: algorithm
                )
            else {
                return Self.addingVary(
                    to: response
                )
            }

            var encoded = response
            encoded.body = .buffer(compressed)

            encoded.headers.replaceOrAdd(
                name: "content-encoding",
                value: algorithm.rawValue
            )
            encoded.headers.replaceOrAdd(
                name: "content-length",
                value: String(
                    compressed.readableBytes
                )
            )

            Self.appendVary(
                to: &encoded.headers
            )

            return encoded

        case .identity, .notAcceptable:
            return Self.addingVary(
                to: response
            )
        }
    }

    private func compressedBody(
        of body: Response.Body,
        algorithm: CompressionAlgorithm
    ) -> ByteBuffer? {
        guard algorithm == .gzip else {
            return nil
        }

        let level =
            Int32(configuration.compressionLevel)

        switch body {
        case .text(let value):
            return Self.compressUTF8(
                value,
                level: level
            )

        case .bytes(let bytes):
            return bytes.withUnsafeBytes {
                buffer in

                ZlibGzip.compress(
                    buffer,
                    level: level
                )
            }

        case .buffer(let buffer):
            return buffer.withUnsafeReadableBytes {
                bytes in

                ZlibGzip.compress(
                    bytes,
                    level: level
                )
            }

        case .empty, .fileRegion, .stream:
            return nil
        }
    }

    private static func compressUTF8(
        _ value: String,
        level: Int32
    ) -> ByteBuffer? {
        let contiguous = value.utf8
            .withContiguousStorageIfAvailable {
                buffer in

                buffer.withUnsafeBytes {
                    bytes in

                    ZlibGzip.compress(
                        bytes,
                        level: level
                    )
                }
            }

        if let contiguous {
            return contiguous
        }

        let bytes = Array(value.utf8)

        return bytes.withUnsafeBytes {
            buffer in

            ZlibGzip.compress(
                buffer,
                level: level
            )
        }
    }

    // MARK: - Vary

    private static let acceptEncodingToken:
        [UInt8] =
        Array("accept-encoding".utf8)

    private static let varyName: [UInt8] =
        Array("vary".utf8)

    private static let wildcardVaryToken: [UInt8] =
        Array("*".utf8)

    private static func addingVary(
        to response: Response
    ) -> Response {
        var response = response
        appendVary(to: &response.headers)
        return response
    }

    internal static func appendVary(
        to headers: inout HTTPHeaders
    ) {
        guard !varyIncludesAcceptEncoding(headers)
        else {
            return
        }

        headers.add(
            name: "vary",
            value: "Accept-Encoding"
        )
    }

    private static func varyIncludesAcceptEncoding(
        _ headers: HTTPHeaders
    ) -> Bool {
        for (name, value) in headers
        where asciiEquals(
            name.utf8,
            varyName
        ) {
            if varyValueIncludesAcceptEncoding(value) {
                return true
            }
        }

        return false
    }

    private static func varyValueIncludesAcceptEncoding(
        _ value: String
    ) -> Bool {
        let bytes = value.utf8
        var position = bytes.startIndex

        while position != bytes.endIndex {
            while position != bytes.endIndex {
                let byte = bytes[position]

                guard
                    byte == 44
                    || isOptionalWhitespace(byte)
                else {
                    break
                }

                bytes.formIndex(after: &position)
            }

            guard position != bytes.endIndex else {
                break
            }

            var end = position

            while
                end != bytes.endIndex,
                bytes[end] != 44
            {
                bytes.formIndex(after: &end)
            }

            var trimmedEnd = end

            while trimmedEnd > position {
                let previous =
                    bytes.index(before: trimmedEnd)

                guard
                    isOptionalWhitespace(
                        bytes[previous]
                    )
                else {
                    break
                }

                trimmedEnd = previous
            }

            let token = bytes[position..<trimmedEnd]

            if asciiEquals(
                token,
                acceptEncodingToken
            ) {
                return true
            }

            if asciiEquals(
                token,
                wildcardVaryToken
            ) {
                return true
            }

            position = end
        }

        return false
    }
}

public extension Application {
    func use(compression: Compression) {
        useFast(compression.middleware())
    }
}
