import NIOCore

/// Incremental server-only HTTP/1 parser over a caller-owned cumulation
/// buffer.
///
/// Stateless value: all incremental state lives in the caller's buffer
/// (head parsing) or in an explicit `WTHTTP1ChunkState` (chunked bodies).
/// Strict by design: any framing ambiguity fails closed with
/// `WTHTTP1ParseError` so the handler can answer 400 and close, mirroring
/// `HTTPServerProtocolErrorHandler`. Documented intentional divergences
/// from llhttp leniency are all in the reject direction.
public struct WTHTTP1Parser: Sendable {
    public var maxHeadBytes: Int
    public var maxHeaders: Int
    public var maxChunkLineBytes: Int
    public var maxTrailerBytes: Int

    public init(
        maxHeadBytes: Int = 65536,
        maxHeaders: Int = 256,
        maxChunkLineBytes: Int = 4096,
        maxTrailerBytes: Int = 16384
    ) {
        precondition(maxHeadBytes > 0)
        precondition(maxHeaders > 0)
        precondition(maxChunkLineBytes > 0)
        precondition(maxTrailerBytes > 0)
        self.maxHeadBytes = maxHeadBytes
        self.maxHeaders = maxHeaders
        self.maxChunkLineBytes = maxChunkLineBytes
        self.maxTrailerBytes = maxTrailerBytes
    }

    /// Parses one request head from the readable bytes.
    ///
    /// Returns `nil` when more data is needed. On success consumes exactly
    /// the head bytes; any body or pipelined bytes stay readable. Throws
    /// on malformed input; the buffer is left unconsumed on throw so the
    /// handler can fail the connection deterministically.
    public func parseHead(
        from buffer: inout ByteBuffer
    ) throws -> WTHTTP1RequestHead? {
        let readable = buffer.readableBytes
        guard readable > 0 else {
            return nil
        }

        guard
            let parsed = try buffer
                .withUnsafeReadableBytes({
                    try scanHead(
                        $0,
                        maxHeadBytes: maxHeadBytes,
                        maxHeaders: maxHeaders
                    )
                })
        else {
            return nil
        }

        let base = buffer.readerIndex
        guard
            let storage = buffer.getSlice(
                at: base,
                length: parsed.headLength
            )
        else {
            preconditionFailure(
                "head slice out of bounds for scanned head"
            )
        }

        buffer.moveReaderIndex(
            to: base + parsed.headLength
        )

        // Scan space is 0-based over the readable bytes and the head
        // starts at the reader, so scan offsets are already storage
        // offsets: `getSlice` returns a rebased 0-based view.
        return WTHTTP1RequestHead(
            storage: storage,
            methodRange: parsed.methodRange,
            uriRange: parsed.uriRange,
            version: parsed.version,
            headerNameRanges: parsed.nameRanges,
            headerValueRanges: parsed.valueRanges,
            framing: parsed.framing,
            keepAlive: parsed.keepAlive,
            expectation: parsed.expectation
        )
    }
}

private struct WTHTTP1ScannedHead {
    var headLength: Int
    var methodRange: Range<Int>
    var uriRange: Range<Int>
    var version: WTHTTP1Version
    var nameRanges: [Range<Int>]
    var valueRanges: [Range<Int>]
    var framing: WTHTTP1BodyFraming
    var keepAlive: Bool
    var expectation: WTHTTP1Expectation
}

private func scanHead(
    _ bytes: UnsafeRawBufferPointer,
    maxHeadBytes: Int,
    maxHeaders: Int
) throws -> WTHTTP1ScannedHead? {
    let count = bytes.count
    var cursor = 0

    func findLF(from start: Int) -> Int? {
        var index = start
        while index < count {
            if bytes[index] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }

    // Request line. Strict CRLF to mirror llhttp: a bare LF is a
    // framing error, not a line ending.
    guard let requestLF = findLF(from: 0) else {
        if count > maxHeadBytes {
            throw WTHTTP1ParseError.headTooLarge
        }
        return nil
    }

    guard requestLF >= 1 && bytes[requestLF - 1] == 13 else {
        throw WTHTTP1ParseError.badRequestLine
    }

    let requestRange = 0..<(requestLF - 1)
    guard !requestRange.isEmpty else {
        throw WTHTTP1ParseError.badRequestLine
    }

    // Runs of SP between the three parts are skipped, mirroring
    // llhttp's separator leniency. Nothing else is: no leading space,
    // no trailing space, no tabs.
    func skipSpaces(from index: Int) -> Int {
        var cursor = index
        while cursor < requestRange.upperBound
            && bytes[cursor] == 32
        {
            cursor += 1
        }
        return cursor
    }

    guard
        let firstSP = findByte(
            32,
            in: bytes,
            range: requestRange
        )
    else {
        throw WTHTTP1ParseError.badRequestLine
    }

    let methodRange = requestRange.lowerBound..<firstSP
    guard
        !methodRange.isEmpty,
        rangeIsToken(bytes, methodRange)
    else {
        throw WTHTTP1ParseError.badRequestLine
    }

    // Unknown methods are rejected to mirror llhttp, which has no
    // custom-method production.
    if case .custom = WTHTTP1Method(
        matching: rangeBytes(bytes, methodRange)
    ) {
        throw WTHTTP1ParseError.badRequestLine
    }

    let uriStart = skipSpaces(from: firstSP + 1)
    guard uriStart < requestRange.upperBound else {
        throw WTHTTP1ParseError.badRequestLine
    }

    guard
        let secondSP = findByte(
            32,
            in: bytes,
            range: uriStart..<requestRange.upperBound
        )
    else {
        throw WTHTTP1ParseError.badRequestLine
    }

    let uriRange = uriStart..<secondSP
    guard
        !uriRange.isEmpty,
        rangeIsURISafe(bytes, uriRange)
    else {
        throw WTHTTP1ParseError.badRequestLine
    }

    let versionStart = skipSpaces(from: secondSP + 1)
    guard versionStart < requestRange.upperBound else {
        throw WTHTTP1ParseError.badRequestLine
    }

    let versionRange = versionStart..<requestRange.upperBound

    // The version must abut the line end: trailing whitespace is
    // rejected, mirroring llhttp.
    if findByte(
        32,
        in: bytes,
        range: versionRange
    ) != nil
        || findByte(
            9,
            in: bytes,
            range: versionRange
        ) != nil
    {
        throw WTHTTP1ParseError.badRequestLine
    }

    let version: WTHTTP1Version
    if rangeEquals(
        bytes,
        versionRange,
        [72, 84, 84, 80, 47, 49, 46, 49]
    ) {
        version = .http11
    } else if rangeEquals(
        bytes,
        versionRange,
        [72, 84, 84, 80, 47, 49, 46, 48]
    ) {
        version = .http10
    } else {
        throw WTHTTP1ParseError.unsupportedVersion
    }

    cursor = requestLF + 1

    // Header block.
    var nameRanges: [Range<Int>] = []
    var valueRanges: [Range<Int>] = []
    nameRanges.reserveCapacity(16)
    valueRanges.reserveCapacity(16)

    var headEnd: Int?
    while true {
        guard let lineLF = findLF(from: cursor) else {
            if count > maxHeadBytes {
                throw WTHTTP1ParseError.headTooLarge
            }
            return nil
        }

        if lineLF + 1 > maxHeadBytes {
            // The head already exceeds the bound without completing.
            throw WTHTTP1ParseError.headTooLarge
        }

        guard lineLF > cursor
            && bytes[lineLF - 1] == 13
        else {
            throw WTHTTP1ParseError.badHeaderLine
        }

        let content = cursor..<(lineLF - 1)
        if content.isEmpty {
            headEnd = lineLF + 1
            break
        }

        guard
            let colon = findByte(
                58,
                in: bytes,
                range: content
            ),
            colon > content.lowerBound
        else {
            throw WTHTTP1ParseError.badHeaderLine
        }

        let nameRange = content.lowerBound..<colon
        guard rangeIsToken(bytes, nameRange) else {
            throw WTHTTP1ParseError.badHeaderLine
        }

        // Leading OWS is stripped but trailing OWS is preserved,
        // mirroring llhttp's observable header-value semantics.
        var valueStart = colon + 1
        let valueEnd = content.upperBound
        while valueStart < valueEnd
            && (bytes[valueStart] == 32
                || bytes[valueStart] == 9)
        {
            valueStart += 1
        }

        var scan = valueStart
        while scan < valueEnd {
            guard
                WTHTTP1Validation.isValidHeaderValueByte(
                    bytes[scan]
                )
            else {
                throw WTHTTP1ParseError.badHeaderLine
            }
            scan += 1
        }

        // The count bound applies to header lines only: the empty
        // terminator line must not trip it.
        guard nameRanges.count < maxHeaders else {
            throw WTHTTP1ParseError.tooManyHeaders
        }

        nameRanges.append(nameRange)
        valueRanges.append(valueStart..<valueEnd)
        cursor = lineLF + 1
    }

    guard let headLength = headEnd else {
        return nil
    }

    let framing = try resolveFraming(
        bytes,
        nameRanges: nameRanges,
        valueRanges: valueRanges,
        version: version
    )

    return WTHTTP1ScannedHead(
        headLength: headLength,
        methodRange: methodRange,
        uriRange: uriRange,
        version: version,
        nameRanges: nameRanges,
        valueRanges: valueRanges,
        framing: framing.body,
        keepAlive: framing.keepAlive,
        expectation: framing.expectation
    )
}

private func findByte(
    _ target: UInt8,
    in bytes: UnsafeRawBufferPointer,
    range: Range<Int>
) -> Int? {
    var index = range.lowerBound
    while index < range.upperBound {
        if bytes[index] == target {
            return index
        }
        index += 1
    }
    return nil
}

private func rangeIsToken(
    _ bytes: UnsafeRawBufferPointer,
    _ range: Range<Int>
) -> Bool {
    guard !range.isEmpty else {
        return false
    }

    var index = range.lowerBound
    while index < range.upperBound {
        guard
            WTHTTP1Validation.isValidHeaderNameByte(
                bytes[index]
            )
        else {
            return false
        }
        index += 1
    }

    return true
}

private func rangeIsURISafe(
    _ bytes: UnsafeRawBufferPointer,
    _ range: Range<Int>
) -> Bool {
    // Visible ASCII only, mirroring llhttp: no spaces, controls,
    // DEL, or non-ASCII bytes. Anything else must be percent-encoded.
    var index = range.lowerBound
    while index < range.upperBound {
        let byte = bytes[index]
        if byte < 33 || byte > 126 {
            return false
        }
        index += 1
    }

    return true
}

private func rangeEquals(
    _ bytes: UnsafeRawBufferPointer,
    _ range: Range<Int>,
    _ expected: [UInt8]
) -> Bool {
    guard range.count == expected.count else {
        return false
    }

    var offset = 0
    var index = range.lowerBound
    while index < range.upperBound {
        guard bytes[index] == expected[offset] else {
            return false
        }
        index += 1
        offset += 1
    }

    return true
}

private struct WTHTTP1ResolvedFraming {
    var body: WTHTTP1BodyFraming
    var keepAlive: Bool
    var expectation: WTHTTP1Expectation
}

/// Setup-initialized framing token bytes: comparing against these
/// allocates nothing per request.
private enum WTHTTP1FramingNames {
    static let contentLength: [UInt8] = [
        99, 111, 110, 116, 101, 110, 116, 45, 108, 101, 110,
        103, 116, 104,
    ]
    static let transferEncoding: [UInt8] = [
        116, 114, 97, 110, 115, 102, 101, 114, 45, 101, 110,
        99, 111, 100, 105, 110, 103,
    ]
    static let connection: [UInt8] = [
        99, 111, 110, 110, 101, 99, 116, 105, 111, 110,
    ]
    static let expect: [UInt8] = [101, 120, 112, 101, 99, 116]
    static let continue100: [UInt8] = [
        49, 48, 48, 45, 99, 111, 110, 116, 105, 110, 117, 101,
    ]
    static let chunked: [UInt8] = [
        99, 104, 117, 110, 107, 101, 100,
    ]
    static let identity: [UInt8] = [
        105, 100, 101, 110, 116, 105, 116, 121,
    ]
    static let close: [UInt8] = [99, 108, 111, 115, 101]
    static let keepAlive: [UInt8] = [
        107, 101, 101, 112, 45, 97, 108, 105, 118, 101,
    ]
}

private func resolveFraming(
    _ bytes: UnsafeRawBufferPointer,
    nameRanges: [Range<Int>],
    valueRanges: [Range<Int>],
    version: WTHTTP1Version
) throws -> WTHTTP1ResolvedFraming {
    var contentLength: Int?
    var sawContentLength = false
    var sawTransferEncoding = false
    var transferEncodingOK = true
    var previousTransferToken: Range<Int>?
    var sawClose = false
    var sawKeepAlive = false
    var expectation: WTHTTP1Expectation = .none
    var sawExpect = false

    for index in nameRanges.indices {
        let nameRange = nameRanges[index]
        let valueRange = valueRanges[index]

        if rangeEqualsFolded(
            bytes,
            nameRange,
            WTHTTP1FramingNames.contentLength
        ) {
            // Any duplicate Content-Length is rejected, mirroring
            // llhttp (even byte-identical ones).
            guard !sawContentLength else {
                throw WTHTTP1ParseError.badContentLength
            }
            sawContentLength = true

            // Trailing OWS is tolerated around the digits, mirroring
            // llhttp's content-length production.
            var digitEnd = valueRange.upperBound
            while digitEnd > valueRange.lowerBound {
                let last = bytes[digitEnd - 1]
                guard last == 32 || last == 9 else {
                    break
                }
                digitEnd -= 1
            }

            let digits = rangeBytes(
                bytes,
                valueRange.lowerBound..<digitEnd
            )
            guard
                !digits.isEmpty,
                digits.allSatisfy({
                    $0 >= 48 && $0 <= 57
                })
            else {
                throw WTHTTP1ParseError.badContentLength
            }

            contentLength = try parseContentLength(digits)
            continue
        }

        if rangeEqualsFolded(
            bytes,
            nameRange,
            WTHTTP1FramingNames.transferEncoding
        ) {
            // Transfer-Encoding follows the llhttp token machine
            // (see the differential corpus): leading OWS is skipped,
            // OWS before a comma is tolerated, but trailing OWS at
            // the end of a value, empty segments, and anything but a
            // comma after a token all fail. Empty values contribute
            // no tokens and are ignored. Token order carries across
            // repeated headers: every token but the last must be
            // "identity" and the last must be "chunked".
            try parseTransferEncodingValue(
                bytes,
                valueRange,
                sawToken: &sawTransferEncoding,
                previousToken: &previousTransferToken,
                tokensOK: &transferEncodingOK
            )

            continue
        }

        if rangeEqualsFolded(
            bytes,
            nameRange,
            WTHTTP1FramingNames.connection
        ) {
            // Note: an `upgrade` token is deliberately NOT treated
            // specially. Stock `HTTPServerPipelineHandler` without
            // configured upgraders routes such requests normally (see
            // WTHTTP1StockBehaviorTests), so rejecting would diverge.
            // Tier 1 simply never performs the handshake.
            for token in splitListTokens(bytes, valueRange) {
                if token
                    == WTHTTP1FramingNames.close
                {
                    sawClose = true
                } else if token
                    == WTHTTP1FramingNames.keepAlive
                {
                    sawKeepAlive = true
                }
            }

            continue
        }

        if !sawExpect
            && rangeEqualsFolded(
                bytes,
                nameRange,
                WTHTTP1FramingNames.expect
            )
        {
            sawExpect = true
            let value = rangeBytes(bytes, valueRange)
            if version == .http11
                && foldedEqual(
                    value,
                    WTHTTP1FramingNames.continue100
                )
            {
                expectation = .continue100
            } else {
                expectation = .unsupported
            }

            continue
        }
    }

    if sawTransferEncoding {
        // The final transfer token must be "chunked"; earlier
        // tokens were already required to be "identity" as each new
        // token arrived.
        guard transferEncodingOK,
            let previousTransferToken,
            rangeEqualsFolded(
                bytes,
                previousTransferToken,
                WTHTTP1FramingNames.chunked
            )
        else {
            throw WTHTTP1ParseError.unsupportedTransferEncoding
        }
    }

    if contentLength != nil && sawTransferEncoding {
        throw WTHTTP1ParseError.ambiguousFraming
    }

    let body: WTHTTP1BodyFraming
    if sawTransferEncoding {
        body = .chunked
    } else if let contentLength {
        body = contentLength == 0 ? .none : .contentLength(
            contentLength
        )
    } else {
        body = .none
    }

    let keepAlive: Bool
    switch version {
    case .http11:
        keepAlive = !sawClose

    case .http10:
        keepAlive = sawKeepAlive && !sawClose
    }

    return WTHTTP1ResolvedFraming(
        body: body,
        keepAlive: keepAlive,
        expectation: expectation
    )
}

private func rangeBytes(
    _ bytes: UnsafeRawBufferPointer,
    _ range: Range<Int>
) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(range.count)
    var index = range.lowerBound
    while index < range.upperBound {
        out.append(bytes[index])
        index += 1
    }
    return out
}

private func rangeEqualsFolded(
    _ bytes: UnsafeRawBufferPointer,
    _ range: Range<Int>,
    _ expected: [UInt8]
) -> Bool {
    guard range.count == expected.count else {
        return false
    }

    var offset = 0
    var index = range.lowerBound
    while index < range.upperBound {
        var byte = bytes[index]
        if byte >= 65 && byte <= 90 {
            byte += 32
        }

        guard byte == expected[offset] else {
            return false
        }

        index += 1
        offset += 1
    }

    return true
}

private func foldedEqual(
    _ lhs: [UInt8],
    _ rhs: [UInt8]
) -> Bool {
    guard lhs.count == rhs.count else {
        return false
    }

    for index in lhs.indices {
        var left = lhs[index]
        let right = rhs[index]

        if left >= 65 && left <= 90 {
            left += 32
        }

        guard left == right else {
            return false
        }
    }

    return true
}

private func parseContentLength(
    _ digits: [UInt8]
) throws -> Int {
    var value = 0
    for digit in digits {
        let (scaled, scaleOverflow) = value
            .multipliedReportingOverflow(by: 10)
        let (next, addOverflow) = scaled
            .addingReportingOverflow(Int(digit - 48))

        guard !scaleOverflow && !addOverflow else {
            throw WTHTTP1ParseError.badContentLength
        }

        value = next
    }

    return value
}

/// Splits a comma-separated header value into lowercased OWS-stripped
/// tokens. Empty elements are dropped.
/// Runs the llhttp Transfer-Encoding token machine over one
/// header value. Zero-allocation: tokens are compared as ranges.
/// Order state carries across repeated headers via the in-out
/// parameters.
private func parseTransferEncodingValue(
    _ bytes: UnsafeRawBufferPointer,
    _ range: Range<Int>,
    sawToken: inout Bool,
    previousToken: inout Range<Int>?,
    tokensOK: inout Bool
) throws {
    var cursor = range.lowerBound

    func skipOWS() {
        while cursor < range.upperBound {
            let byte = bytes[cursor]
            guard byte == 32 || byte == 9 else {
                return
            }
            cursor += 1
        }
    }

    skipOWS()

    // An empty (or all-OWS) value contributes no tokens.
    guard cursor < range.upperBound else {
        return
    }

    while true {
        let tokenStart = cursor
        while cursor < range.upperBound {
            let byte = bytes[cursor]
            guard byte != 44 && byte != 32 && byte != 9 else {
                break
            }
            cursor += 1
        }

        let token = tokenStart..<cursor
        guard !token.isEmpty else {
            throw WTHTTP1ParseError.unsupportedTransferEncoding
        }

        // Every token but the last must be "identity": checked here
        // as each new token arrives.
        if sawToken,
            let previous = previousToken,
            !rangeEqualsFolded(
                bytes,
                previous,
                WTHTTP1FramingNames.identity
            )
        {
            tokensOK = false
        }
        sawToken = true
        previousToken = token

        guard cursor < range.upperBound else {
            return
        }

        let byte = bytes[cursor]
        if byte == 44 {
            cursor += 1
            skipOWS()
            guard cursor < range.upperBound else {
                throw WTHTTP1ParseError.unsupportedTransferEncoding
            }
            continue
        }

        guard byte == 32 || byte == 9 else {
            throw WTHTTP1ParseError.unsupportedTransferEncoding
        }

        skipOWS()

        // Trailing OWS at the end of the value fails; OWS before a
        // comma is tolerated.
        guard cursor < range.upperBound else {
            throw WTHTTP1ParseError.unsupportedTransferEncoding
        }

        guard bytes[cursor] == 44 else {
            throw WTHTTP1ParseError.unsupportedTransferEncoding
        }

        cursor += 1
        skipOWS()
        guard cursor < range.upperBound else {
            throw WTHTTP1ParseError.unsupportedTransferEncoding
        }
    }
}

private func splitListTokens(
    _ bytes: UnsafeRawBufferPointer,
    _ range: Range<Int>
) -> [[UInt8]] {
    var tokens: [[UInt8]] = []
    var current: [UInt8] = []

    func flush() {
        var start = current.startIndex
        var end = current.endIndex

        while start < end
            && (current[start] == 32
                || current[start] == 9)
        {
            start += 1
        }

        while end > start
            && (current[end - 1] == 32
                || current[end - 1] == 9)
        {
            end -= 1
        }

        if start < end {
            var token: [UInt8] = []
            token.reserveCapacity(end - start)
            var index = start
            while index < end {
                var byte = current[index]
                if byte >= 65 && byte <= 90 {
                    byte += 32
                }
                token.append(byte)
                index += 1
            }
            tokens.append(token)
        }

        current.removeAll(keepingCapacity: true)
    }

    var index = range.lowerBound
    while index < range.upperBound {
        let byte = bytes[index]
        if byte == 44 {
            flush()
        } else {
            current.append(byte)
        }
        index += 1
    }
    flush()

    return tokens
}

// MARK: - Chunked body parsing

/// Explicit chunked-body state across buffer feeds. Owned by the
/// connection handler; the parser only advances it.
public struct WTHTTP1ChunkState: Sendable {
    fileprivate enum Position: Sendable {
        case sizeLine
        case data(remaining: Int)
        case dataEnd
        case end
    }

    fileprivate var position: Position = .sizeLine

    public init() {}
}

/// One chunked-body step result.
public enum WTHTTP1ChunkEvent: Sendable, Equatable {
    case needMoreData
    case data(ByteBuffer)
    case end
}

extension WTHTTP1Parser {
    /// Advances one chunked-body step over the readable bytes.
    ///
    /// Returns `.data` slices incrementally so the handler can enforce
    /// body limits per chunk, mirroring the stock streaming path. Chunk
    /// extensions are accepted and ignored; trailers are rejected
    /// (Tier 1 scope). Chunk framing requires strict CRLF.
    public func parseChunk(
        from buffer: inout ByteBuffer,
        state: inout WTHTTP1ChunkState
    ) throws -> WTHTTP1ChunkEvent {
        while true {
            switch state.position {
            case .sizeLine:
                guard
                    let outcome = try parseChunkSize(
                        from: &buffer
                    )
                else {
                    return .needMoreData
                }

                if outcome == 0 {
                    state.position = .end
                } else {
                    state.position = .data(
                        remaining: outcome
                    )
                }

            case .data(let remaining):
                guard buffer.readableBytes > 0 else {
                    return .needMoreData
                }

                let take = min(
                    remaining,
                    buffer.readableBytes
                )
                guard
                    let slice = buffer.readSlice(
                        length: take
                    )
                else {
                    preconditionFailure(
                        "chunk slice out of bounds"
                    )
                }

                if take == remaining {
                    state.position = .dataEnd
                } else {
                    state.position = .data(
                        remaining: remaining - take
                    )
                }

                return .data(slice)

            case .dataEnd:
                guard buffer.readableBytes >= 2 else {
                    return .needMoreData
                }

                guard
                    buffer.getInteger(
                        at: buffer.readerIndex,
                        as: UInt16.self
                    ) == 0x0d0a
                else {
                    throw WTHTTP1ParseError.badChunkFraming
                }

                buffer.moveReaderIndex(
                    forwardBy: 2
                )
                state.position = .sizeLine

            case .end:
                // Trailer section: validated line by line with the
                // same header rules, then discarded. Bounded so a
                // trailer flood cannot grow the cumulation without
                // end, mirroring stock acceptance without keeping
                // values no Tier 1 consumer reads.
                var trailerBytes = 0

                while true {
                    guard
                        let lineLength = try findCRLF(
                            in: buffer
                        )
                    else {
                        if buffer.readableBytes
                            > maxChunkLineBytes
                        {
                            throw WTHTTP1ParseError
                                .badChunkFraming
                        }

                        return .needMoreData
                    }

                    trailerBytes += lineLength + 2
                    guard trailerBytes <= maxTrailerBytes else {
                        throw WTHTTP1ParseError
                            .badChunkFraming
                    }

                    if lineLength == 0 {
                        buffer.moveReaderIndex(
                            forwardBy: 2
                        )
                        return .end
                    }

                    try validateTrailerLine(
                        in: buffer,
                        length: lineLength
                    )
                    buffer.moveReaderIndex(
                        forwardBy: lineLength + 2
                    )
                }
            }
        }
    }

    private func parseChunkSize(
        from buffer: inout ByteBuffer
    ) throws -> Int? {
        guard
            let lineLength = try findCRLF(
                in: buffer
            )
        else {
            if buffer.readableBytes > maxChunkLineBytes {
                throw WTHTTP1ParseError.badChunkFraming
            }

            return nil
        }

        guard
            let line = buffer.getSlice(
                at: buffer.readerIndex,
                length: lineLength
            )
        else {
            preconditionFailure(
                "chunk line slice out of bounds"
            )
        }

        var size = 0
        var sawDigit = false
        var cursor = line.readerIndex
        let lineEnd = line.writerIndex

        while cursor < lineEnd {
            guard let byte: UInt8 = line.getInteger(
                at: cursor
            ) else {
                preconditionFailure(
                    "chunk line read out of bounds"
                )
            }

            if byte == 59 {
                break
            }

            let digit: Int
            switch byte {
            case 48...57:
                digit = Int(byte - 48)

            case 65...70:
                digit = Int(byte - 55)

            case 97...102:
                digit = Int(byte - 87)

            default:
                throw WTHTTP1ParseError.badChunkFraming
            }

            sawDigit = true
            let (scaled, scaleOverflow) = size
                .multipliedReportingOverflow(by: 16)
            let (next, addOverflow) = scaled
                .addingReportingOverflow(digit)

            guard !scaleOverflow && !addOverflow else {
                throw WTHTTP1ParseError.badChunkFraming
            }

            size = next
            cursor += 1
        }

        guard sawDigit else {
            throw WTHTTP1ParseError.badChunkFraming
        }

        // Chunk extensions (after ';') are accepted and ignored, but
        // must not smuggle control bytes.
        while cursor < lineEnd {
            guard let byte: UInt8 = line.getInteger(
                at: cursor
            ) else {
                preconditionFailure(
                    "chunk extension read out of bounds"
                )
            }

            guard
                byte == 9 || byte == 32 || byte >= 33
                    && byte != 127 || byte >= 128
            else {
                throw WTHTTP1ParseError.badChunkFraming
            }

            cursor += 1
        }

        buffer.moveReaderIndex(
            forwardBy: lineLength + 2
        )
        return size
    }

    private func validateTrailerLine(
        in buffer: ByteBuffer,
        length: Int
    ) throws {
        let base = buffer.readerIndex
        var colon: Int?

        for offset in 0..<length {
            guard
                let byte: UInt8 = buffer.getInteger(
                    at: base + offset
                )
            else {
                preconditionFailure(
                    "trailer line read out of bounds"
                )
            }

            if byte == 58 {
                colon = offset
                break
            }

            guard
                WTHTTP1Validation.isValidHeaderNameByte(
                    byte
                )
            else {
                throw WTHTTP1ParseError.badChunkFraming
            }
        }

        guard let colon, colon > 0 else {
            throw WTHTTP1ParseError.badChunkFraming
        }

        // Trailing OWS is rejected exactly like header values.
        if length - (colon + 1) > 0 {
            guard
                let last: UInt8 = buffer.getInteger(
                    at: base + length - 1
                )
            else {
                preconditionFailure(
                    "trailer value read out of bounds"
                )
            }

            if last == 32 || last == 9 {
                throw WTHTTP1ParseError.badChunkFraming
            }
        }

        for offset in (colon + 1)..<length {
            guard
                let byte: UInt8 = buffer.getInteger(
                    at: base + offset
                )
            else {
                preconditionFailure(
                    "trailer value read out of bounds"
                )
            }

            guard
                WTHTTP1Validation.isValidHeaderValueByte(
                    byte
                )
            else {
                throw WTHTTP1ParseError.badChunkFraming
            }
        }
    }

    /// Length of the current line excluding CRLF, or nil when no
    /// complete line is readable yet. Strict CRLF: a bare LF in chunk
    /// framing throws to match llhttp.
    private func findCRLF(
        in buffer: ByteBuffer
    ) throws -> Int? {
        let readable = buffer.readableBytes
        var offset = 0

        while offset < readable {
            guard
                let byte: UInt8 = buffer.getInteger(
                    at: buffer.readerIndex + offset
                )
            else {
                return nil
            }

            if byte == 10 {
                guard offset >= 1 else {
                    throw WTHTTP1ParseError.badChunkFraming
                }

                guard
                    let previous: UInt8 = buffer.getInteger(
                        at: buffer.readerIndex + offset - 1
                    ),
                    previous == 13
                else {
                    throw WTHTTP1ParseError.badChunkFraming
                }

                return offset - 1
            }

            offset += 1
        }

        return nil
    }
}
