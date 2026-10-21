public enum SQLStatementSplitterError:
    Error,
    Sendable,
    Equatable
{
    case unterminatedString
    case unterminatedQuotedIdentifier
    case unterminatedBlockComment
    case unterminatedDollarQuote
}

public enum SQLStatementSplitter {
    /// Split a SQL file into individual statements.
    ///
    /// Semicolons inside single-quoted strings, double-quoted identifiers,
    /// line comments, nested block comments, and PostgreSQL dollar-quoted
    /// bodies are preserved. Comments are replaced by one space and are not
    /// included in the resulting statements. Unterminated strings, quoted
    /// identifiers, dollar quotes, and block comments throw instead of
    /// silently dropping part of the input. SQL-standard `BEGIN ATOMIC`
    /// function bodies are not tracked; use dollar-quoted bodies instead.
    public static func split(
        _ sql: String
    ) throws -> [String] {
        let bytes =
            Array(sql.utf8)
        var statements:
            [String] = []
        var current:
            [UInt8] = []
        var index = 0

        enum State {
            case normal
            case singleQuote(backslashEscapes: Bool)
            case doubleQuote
            case lineComment
            case blockComment(depth: Int)
            case dollarQuote(tag: [UInt8])
        }

        var state =
            State.normal

        while index < bytes.count {
            let byte =
                bytes[index]

            switch state {
            case .normal:
                if byte == 45,
                   index + 1 < bytes.count,
                   bytes[index + 1] == 45
                {
                    current.append(32)
                    index += 2
                    state = .lineComment
                    continue
                }

                if byte == 47,
                   index + 1 < bytes.count,
                   bytes[index + 1] == 42
                {
                    current.append(32)
                    index += 2
                    state = .blockComment(
                        depth: 1
                    )
                    continue
                }

                if byte == 39 {
                    let escapeString =
                        isEscapeStringPrefix(
                            in: bytes,
                            quoteIndex: index
                        )

                    current.append(byte)
                    index += 1
                    state = .singleQuote(
                        backslashEscapes:
                            escapeString
                    )
                    continue
                }

                if byte == 34 {
                    current.append(byte)
                    index += 1
                    state = .doubleQuote
                    continue
                }

                if byte == 36,
                   !startsAfterIdentifier(
                       current
                   ),
                   let tag = dollarTag(
                       in: bytes,
                       at: index
                   )
                {
                    current.append(
                        contentsOf: tag
                    )
                    index += tag.count
                    state = .dollarQuote(
                        tag: tag
                    )
                    continue
                }

                if byte == 59 {
                    appendStatement(
                        from: current,
                        to: &statements
                    )
                    current.removeAll(
                        keepingCapacity: true
                    )
                    index += 1
                    continue
                }

                current.append(byte)
                index += 1

            case .singleQuote(let backslashEscapes):
                current.append(byte)
                index += 1

                if byte == 39 {
                    if index < bytes.count,
                       bytes[index] == 39
                    {
                        current.append(
                            bytes[index]
                        )
                        index += 1
                    } else {
                        state = .normal
                    }
                } else if backslashEscapes,
                          byte == 92,
                          index < bytes.count
                {
                    current.append(
                        bytes[index]
                    )
                    index += 1
                }

            case .doubleQuote:
                current.append(byte)
                index += 1

                if byte == 34 {
                    if index < bytes.count,
                       bytes[index] == 34
                    {
                        current.append(
                            bytes[index]
                        )
                        index += 1
                    } else {
                        state = .normal
                    }
                }

            case .lineComment:
                index += 1

                if byte == 10 || byte == 13 {
                    state = .normal
                }

            case .blockComment(let depth):
                if byte == 47,
                   index + 1 < bytes.count,
                   bytes[index + 1] == 42
                {
                    index += 2
                    state = .blockComment(
                        depth: depth + 1
                    )
                } else if byte == 42,
                          index + 1 < bytes.count,
                          bytes[index + 1] == 47
                {
                    index += 2

                    if depth == 1 {
                        state = .normal
                    } else {
                        state = .blockComment(
                            depth: depth - 1
                        )
                    }
                } else {
                    index += 1
                }

            case .dollarQuote(let tag):
                if matches(
                    tag,
                    in: bytes,
                    at: index
                ) {
                    current.append(
                        contentsOf: tag
                    )
                    index += tag.count
                    state = .normal
                } else {
                    current.append(byte)
                    index += 1
                }
            }
        }

        switch state {
        case .normal, .lineComment:
            break

        case .singleQuote:
            throw SQLStatementSplitterError
                .unterminatedString

        case .doubleQuote:
            throw SQLStatementSplitterError
                .unterminatedQuotedIdentifier

        case .blockComment:
            throw SQLStatementSplitterError
                .unterminatedBlockComment

        case .dollarQuote:
            throw SQLStatementSplitterError
                .unterminatedDollarQuote
        }

        appendStatement(
            from: current,
            to: &statements
        )

        return statements
    }

    private static func appendStatement(
        from bytes: [UInt8],
        to statements: inout [String]
    ) {
        var start = 0
        var end = bytes.count

        while start < end,
              isWhitespace(bytes[start])
        {
            start += 1
        }

        while end > start,
              isWhitespace(bytes[end - 1])
        {
            end -= 1
        }

        guard start < end else {
            return
        }

        statements.append(
            String(
                decoding:
                    bytes[start..<end],
                as: UTF8.self
            )
        )
    }

    private static func isWhitespace(
        _ byte: UInt8
    ) -> Bool {
        switch byte {
        case 9, 10, 11, 12, 13, 32:
            return true
        default:
            return false
        }
    }

    /// PostgreSQL uses backslash escapes only in `E'...'` strings. Standard
    /// strings (the default with `standard_conforming_strings=on`) treat a
    /// backslash as an ordinary character, so `'C:\'` must close at the quote.
    private static func isEscapeStringPrefix(
        in bytes: [UInt8],
        quoteIndex: Int
    ) -> Bool {
        guard quoteIndex > 0 else {
            return false
        }

        let prefix =
            bytes[quoteIndex - 1]

        guard prefix == 69 || prefix == 101 else {
            return false
        }

        guard quoteIndex > 1 else {
            return true
        }

        return !isIdentifierContinuation(
            bytes[quoteIndex - 2]
        )
    }

    private static func matches(
        _ tag: [UInt8],
        in bytes: [UInt8],
        at index: Int
    ) -> Bool {
        guard index + tag.count <= bytes.count else {
            return false
        }

        for offset in 0..<tag.count {
            if bytes[index + offset] != tag[offset] {
                return false
            }
        }

        return true
    }

    private static func dollarTag(
        in bytes: [UInt8],
        at index: Int
    ) -> [UInt8]? {
        guard index < bytes.count,
              bytes[index] == 36
        else {
            return nil
        }

        var cursor =
            index + 1

        if cursor < bytes.count,
           bytes[cursor] == 36
        {
            return [36, 36]
        }

        guard cursor < bytes.count,
              isTagStart(bytes[cursor])
        else {
            return nil
        }

        cursor += 1

        while cursor < bytes.count,
              isTagContinuation(bytes[cursor])
        {
            cursor += 1
        }

        guard cursor < bytes.count,
              bytes[cursor] == 36
        else {
            return nil
        }

        return Array(
            bytes[index...cursor]
        )
    }

    private static func isTagStart(
        _ byte: UInt8
    ) -> Bool {
        (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || byte == 95
            || byte >= 128
    }

    private static func isTagContinuation(
        _ byte: UInt8
    ) -> Bool {
        isTagStart(byte)
            || (byte >= 48 && byte <= 57)
    }

    private static func isIdentifierContinuation(
        _ byte: UInt8
    ) -> Bool {
        isTagContinuation(byte)
            || byte == 36
    }

    /// PostgreSQL does not start a dollar-quoted string immediately after an
    /// identifier or keyword: `a$b$c` is a single identifier, not `a` plus a
    /// dollar quote. A digit run at the end of the preceding token is a
    /// numeric literal or parameter, so `1$tag$...$tag$` still starts a dollar
    /// quote.
    private static func startsAfterIdentifier(
        _ bytes: [UInt8]
    ) -> Bool {
        var index = bytes.count - 1

        while index >= 0,
              isIdentifierContinuation(bytes[index])
        {
            index -= 1
        }

        return bytes[(index + 1)...].contains {
            isTagStart($0)
        }
    }
}
