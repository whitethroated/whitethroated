import NIOHTTP1

/// `Accept-Encoding` negotiation for a fixed, setup-time algorithm
/// set.
///
/// Parsing is byte-oriented and allocation-free on the request path
/// when header values are contiguous (the common case). Malformed
/// quality parameters are ignored together with their element.
///
/// Rules follow RFC 9110 section 12.5.3:
///
/// - an absent header selects identity;
/// - a present header only accepts codings it lists (`*` covers
///   unlisted codings);
/// - identity is acceptable unless explicitly excluded;
/// - `q=0` means "not acceptable";
/// - equal quality prefers the server's configured algorithm order.
internal struct AcceptEncodingNegotiator: Sendable {
    internal enum Decision: Sendable {
        case algorithm(Int)
        case identity
        case notAcceptable
    }

    private static let identityToken: [UInt8] =
        Array("identity".utf8)

    private static let wildcardToken: [UInt8] =
        Array("*".utf8)

    private static let qualityParameterToken: [UInt8] =
        Array("q".utf8)

    private static let acceptEncodingName: [UInt8] =
        Array("accept-encoding".utf8)

    private let tokens: [[UInt8]]

    internal init(
        algorithms: [CompressionAlgorithm]
    ) {
        self.tokens = algorithms.map {
            Array($0.rawValue.utf8)
        }
    }

    internal func decide(
        headers: HTTPHeaders
    ) -> Decision {
        var sawHeader = false
        var identityQuality = -1
        var wildcardQuality = -1

        return withUnsafeTemporaryAllocation(
            of: Int.self,
            capacity: max(1, tokens.count)
        ) { explicit in
            for index in 0..<tokens.count {
                explicit[index] = -1
            }

            for (name, value) in headers
            where asciiEquals(
                name.utf8,
                Self.acceptEncodingName
            ) {
                sawHeader = true
                parse(
                    value: value,
                    explicit: explicit,
                    identityQuality:
                        &identityQuality,
                    wildcardQuality:
                        &wildcardQuality
                )
            }

            guard sawHeader else {
                return .identity
            }

            var bestIndex = -1
            var bestQuality = 0

            for index in 0..<tokens.count {
                let explicitQuality =
                    explicit[index]

                let quality: Int

                if explicitQuality >= 0 {
                    quality = explicitQuality
                } else if wildcardQuality >= 0 {
                    quality = wildcardQuality
                } else {
                    quality = 0
                }

                if quality > bestQuality {
                    bestQuality = quality
                    bestIndex = index
                }
            }

            let identity: Int

            if identityQuality >= 0 {
                identity = identityQuality
            } else if wildcardQuality >= 0 {
                identity = wildcardQuality
            } else {
                identity = 1000
            }

            if bestIndex >= 0, bestQuality >= identity {
                return .algorithm(bestIndex)
            }

            return identity > 0
                ? .identity
                : .notAcceptable
        }
    }

    private func parse(
        value: String,
        explicit: UnsafeMutableBufferPointer<Int>,
        identityQuality: inout Int,
        wildcardQuality: inout Int
    ) {
        let handled = value.utf8
            .withContiguousStorageIfAvailable {
                buffer -> Bool in

                parse(
                    buffer,
                    explicit: explicit,
                    identityQuality:
                        &identityQuality,
                    wildcardQuality:
                        &wildcardQuality
                )

                return true
            }

        guard handled != true else {
            return
        }

        let bytes = Array(value.utf8)

        bytes.withUnsafeBufferPointer { buffer in
            parse(
                buffer,
                explicit: explicit,
                identityQuality:
                    &identityQuality,
                wildcardQuality:
                    &wildcardQuality
            )
        }
    }

    private func parse<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        explicit: UnsafeMutableBufferPointer<Int>,
        identityQuality: inout Int,
        wildcardQuality: inout Int
    ) where Bytes.Element == UInt8 {
        let count = bytes.count
        var position = 0

        while position < count {
            while position < count {
                let byte = self.byte(
                    bytes,
                    at: position
                )

                guard
                    byte == 44
                    || isOptionalWhitespace(byte)
                else {
                    break
                }

                position += 1
            }

            guard position < count else {
                return
            }

            let tokenStart = position

            while position < count {
                let byte = self.byte(
                    bytes,
                    at: position
                )

                guard byte != 44, byte != 59 else {
                    break
                }

                position += 1
            }

            var tokenEnd = position

            while
                tokenEnd > tokenStart,
                isOptionalWhitespace(
                    self.byte(bytes, at: tokenEnd - 1)
                )
            {
                tokenEnd -= 1
            }

            var matchedAlgorithm = -1
            var isIdentity = false
            var isWildcard = false

            if tokenEnd > tokenStart {
                let token = bytes[
                    index(bytes, at: tokenStart)
                        ..< index(bytes, at: tokenEnd)
                ]

                for (
                    index,
                    expected
                ) in tokens.enumerated()
                where matchedAlgorithm == -1 {
                    if asciiEquals(
                        token,
                        expected
                    ) {
                        matchedAlgorithm = index
                    }
                }

                if matchedAlgorithm == -1 {
                    isIdentity = asciiEquals(
                        token,
                        Self.identityToken
                    )

                    isWildcard =
                        !isIdentity
                        && asciiEquals(
                            token,
                            Self.wildcardToken
                        )
                }
            }

            var quality = 1000
            var malformed = false

            if
                position < count,
                self.byte(bytes, at: position) == 59
            {
                parseParameters(
                    bytes,
                    from: position,
                    quality: &quality,
                    malformed: &malformed
                )
            }

            if !malformed {
                if matchedAlgorithm >= 0 {
                    explicit[matchedAlgorithm] = max(
                        explicit[matchedAlgorithm],
                        quality
                    )
                } else if isIdentity {
                    identityQuality = max(
                        identityQuality,
                        quality
                    )
                } else if isWildcard {
                    wildcardQuality = max(
                        wildcardQuality,
                        quality
                    )
                }
            }

            while position < count {
                let byte = self.byte(
                    bytes,
                    at: position
                )

                guard byte == 44 else {
                    position += 1
                    continue
                }

                break
            }
        }
    }

    private func parseParameters<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        from start: Int,
        quality: inout Int,
        malformed: inout Bool
    ) where Bytes.Element == UInt8 {
        let count = bytes.count
        var position = start + 1
        var parsedQuality: Int?

        while position < count {
            let byte = self.byte(
                bytes,
                at: position
            )

            guard byte != 44 else {
                break
            }

            if isOptionalWhitespace(byte) {
                position += 1
                continue
            }

            if byte == 59 {
                position += 1
                continue
            }

            let nameStart = position

            while position < count {
                let current = self.byte(
                    bytes,
                    at: position
                )

                guard
                    current != 61,
                    current != 59,
                    current != 44
                else {
                    break
                }

                position += 1
            }

            let nameEnd = position
            var valueStart = position
            var valueEnd = position

            if
                position < count,
                self.byte(bytes, at: position) == 61
            {
                position += 1

                while
                    position < count,
                    isOptionalWhitespace(
                        self.byte(
                            bytes,
                            at: position
                        )
                    )
                {
                    position += 1
                }

                valueStart = position

                while position < count {
                    let current = self.byte(
                        bytes,
                        at: position
                    )

                    guard current != 59, current != 44
                    else {
                        break
                    }

                    position += 1
                }

                valueEnd = position

                while
                    valueEnd > valueStart,
                    isOptionalWhitespace(
                        self.byte(
                            bytes,
                            at: valueEnd - 1
                        )
                    )
                {
                    valueEnd -= 1
                }
            }

            let name = bytes[
                index(bytes, at: nameStart)
                    ..< index(bytes, at: nameEnd)
            ]

            guard asciiEquals(
                name,
                Self.qualityParameterToken
            ) else {
                continue
            }

            let value = bytes[
                index(bytes, at: valueStart)
                    ..< index(bytes, at: valueEnd)
            ]

            if let parsed = parseQuality(value) {
                parsedQuality = max(
                    parsedQuality ?? 0,
                    parsed
                )
            } else {
                malformed = true
            }
        }

        if let parsedQuality {
            quality = parsedQuality
        }
    }

    private func parseQuality<Bytes: RandomAccessCollection>(
        _ bytes: Bytes
    ) -> Int? where Bytes.Element == UInt8 {
        let count = bytes.count

        guard count > 0 else {
            return nil
        }

        let whole: Int

        switch byte(bytes, at: 0) {
        case 48:
            whole = 0

        case 49:
            whole = 1000

        default:
            return nil
        }

        var position = 1

        guard position < count else {
            return whole
        }

        guard byte(bytes, at: position) == 46 else {
            return nil
        }

        position += 1

        var fraction = 0
        var digits = 0

        while position < count {
            let digit = byte(
                bytes,
                at: position
            )

            guard digit >= 48, digit <= 57 else {
                return nil
            }

            guard digits < 3 else {
                return nil
            }

            fraction =
                fraction * 10
                + Int(digit - 48)

            digits += 1
            position += 1
        }

        guard whole != 1000 || fraction == 0 else {
            return nil
        }

        switch digits {
        case 1:
            fraction *= 100

        case 2:
            fraction *= 10

        default:
            break
        }

        return whole + fraction
    }

    @inline(__always)
    private func byte<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        at offset: Int
    ) -> UInt8 where Bytes.Element == UInt8 {
        bytes[
            index(bytes, at: offset)
        ]
    }

    @inline(__always)
    private func index<Bytes: RandomAccessCollection>(
        _ bytes: Bytes,
        at offset: Int
    ) -> Bytes.Index where Bytes.Element == UInt8 {
        bytes.index(
            bytes.startIndex,
            offsetBy: offset
        )
    }
}
