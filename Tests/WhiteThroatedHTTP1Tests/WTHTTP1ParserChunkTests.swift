import Testing

import NIOCore

@testable import WhiteThroatedHTTP1

private func chunkBuffer(
    _ string: String
) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(
        capacity: string.utf8.count
    )
    buffer.writeString(string)
    return buffer
}

private func drainChunks(
    _ string: String,
    parser: WTHTTP1Parser = WTHTTP1Parser()
) throws -> ByteBuffer {
    var buffer = chunkBuffer(string)
    var state = WTHTTP1ChunkState()
    var out = ByteBufferAllocator().buffer(capacity: 0)

    while true {
        switch try parser.parseChunk(
            from: &buffer,
            state: &state
        ) {
        case .needMoreData:
            Issue.record("unexpected needMoreData")
            return out

        case .data(var slice):
            out.writeBuffer(&slice)

        case .end:
            return out
        }
    }
}

private func bufferString(
    _ buffer: ByteBuffer
) -> String {
    var copy = buffer
    return copy.readString(
        length: copy.readableBytes
    ) ?? "<binary>"
}

@Suite struct WTHTTP1ParserChunkTests {
    @Test func singleChunk() throws {
        let body = try drainChunks("5\r\nhello\r\n0\r\n\r\n")
        #expect(bufferString(body) == "hello")
    }

    @Test func multipleChunks() throws {
        let body = try drainChunks(
            "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        )
        #expect(bufferString(body) == "hello world")
    }

    @Test func hexSizesCaseInsensitive() throws {
        let body = try drainChunks(
            "a\r\n0123456789\r\nA\r\nABCDEFGHIJ\r\n0\r\n\r\n"
        )
        #expect(
            bufferString(body) == "0123456789ABCDEFGHIJ"
        )
    }

    @Test func chunkExtensionsIgnored() throws {
        let body = try drainChunks(
            "5;ext=1;foo=\"bar baz\"\r\nhello\r\n0;done\r\n\r\n"
        )
        #expect(bufferString(body) == "hello")
    }

    @Test func emptyBody() throws {
        var buffer = chunkBuffer("0\r\n\r\n")
        var state = WTHTTP1ChunkState()
        let event = try WTHTTP1Parser().parseChunk(
            from: &buffer,
            state: &state
        )

        #expect(event == .end)
        #expect(buffer.readableBytes == 0)
    }

    @Test func zeroSizeSpellings() throws {
        for size in ["0", "00", "0000000"] {
            let body = try drainChunks(
                "\(size)\r\n\r\n"
            )
            #expect(body.readableBytes == 0)
        }
    }

    @Test func dataMayContainCRLF() throws {
        let body = try drainChunks(
            "6\r\na\r\nb\r\n\r\n0\r\n\r\n"
        )
        #expect(bufferString(body) == "a\r\nb\r\n")
    }

    @Test func splitFeeds() throws {
        let parser = WTHTTP1Parser()
        var buffer = chunkBuffer("5\r\nhel")
        var state = WTHTTP1ChunkState()

        let first = try parser.parseChunk(
            from: &buffer,
            state: &state
        )
        guard case .data(let slice) = first else {
            Issue.record("expected partial data, got \(first)")
            return
        }
        #expect(bufferString(slice) == "hel")

        let stalled = try parser.parseChunk(
            from: &buffer,
            state: &state
        )
        #expect(stalled == .needMoreData)

        buffer.writeString("lo\r\n0\r\n")
        let second = try parser.parseChunk(
            from: &buffer,
            state: &state
        )
        guard case .data(let rest) = second else {
            Issue.record("expected data, got \(second)")
            return
        }
        #expect(bufferString(rest) == "lo")

        let stalledEnd = try parser.parseChunk(
            from: &buffer,
            state: &state
        )
        #expect(stalledEnd == .needMoreData)

        buffer.writeString("\r\n")
        let done = try parser.parseChunk(
            from: &buffer,
            state: &state
        )
        #expect(done == .end)
        #expect(buffer.readableBytes == 0)
    }

    @Test func splitMidSizeLine() throws {
        let parser = WTHTTP1Parser()
        var buffer = chunkBuffer("1")
        var state = WTHTTP1ChunkState()

        #expect(
            try parser.parseChunk(
                from: &buffer,
                state: &state
            ) == .needMoreData
        )

        buffer.writeString("0\r\n0123456789abcdef\r\n0\r\n\r\n")
        var out = ByteBufferAllocator().buffer(capacity: 0)
        while true {
            switch try parser.parseChunk(
                from: &buffer,
                state: &state
            ) {
            case .needMoreData:
                Issue.record("unexpected stall")
                return

            case .data(var slice):
                out.writeBuffer(&slice)

            case .end:
                #expect(
                    bufferString(out)
                        == "0123456789abcdef"
                )
                return
            }
        }
    }

    @Test func pipelinedBytesPreservedAfterEnd() throws {
        var buffer = chunkBuffer(
            "0\r\n\r\nGET /next HTTP/1.1\r\n\r\n"
        )
        var state = WTHTTP1ChunkState()
        let done = try WTHTTP1Parser().parseChunk(
            from: &buffer,
            state: &state
        )

        #expect(done == .end)
        #expect(
            buffer.getString(
                at: buffer.readerIndex,
                length: 3
            ) == "GET"
        )
    }

    @Test func largeChunk() throws {
        let payload = String(
            repeating: "ab",
            count: 32768
        )
        let body = try drainChunks(
            "10000\r\n\(payload)\r\n0\r\n\r\n"
        )

        #expect(bufferString(body) == payload)
    }

    @Test func badHexSize() throws {
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try drainChunks("G\r\n\r\n0\r\n\r\n")
        }
    }

    @Test func emptySizeLine() throws {
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try drainChunks("\r\n0\r\n\r\n")
        }
    }

    @Test func sizeLineWithoutDigits() throws {
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try drainChunks(";ext=1\r\n0\r\n\r\n")
        }
    }

    @Test func missingDataEndCRLF() throws {
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try drainChunks("5\r\nhelloXX0\r\n\r\n")
        }
    }

    @Test func bareLFInChunkFraming() throws {
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try drainChunks("5\nhello\r\n0\r\n\r\n")
        }
    }

    @Test func trailersParsedAndDiscarded() throws {
        let body = try drainChunks(
            "5\r\nhello\r\n0\r\nX-Trailer: v\r\n\r\n"
        )
        #expect(bufferString(body) == "hello")
    }

    @Test func multipleTrailersDiscarded() throws {
        let body = try drainChunks(
            "3\r\nabc\r\n0\r\nA: 1\r\nB: two\r\n\r\n"
        )
        #expect(bufferString(body) == "abc")
    }

    @Test func trailerGarbageRejected() throws {
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try drainChunks(
                "3\r\nabc\r\n0\r\nno-colon-here\r\n\r\n"
            )
        }
    }

    @Test func trailerTrailingOWSAcceptedLikeStock() throws {
        // llhttp keeps trailing OWS in trailer values (differential
        // corpus); Tier 1 mirrors accept and discards the value.
        let body = try drainChunks(
            "3\r\nabc\r\n0\r\nA: v \r\n\r\n"
        )
        #expect(bufferString(body) == "abc")
    }

    @Test func trailerFloodBounded() throws {
        let parser = WTHTTP1Parser(maxTrailerBytes: 16)
        var buffer = chunkBuffer(
            "3\r\nabc\r\n0\r\nA: 12345678901234567890\r\n\r\n"
        )
        var state = WTHTTP1ChunkState()
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            while true {
                let event = try parser.parseChunk(
                    from: &buffer,
                    state: &state
                )

                if case .end = event {
                    break
                }

                if case .needMoreData = event {
                    Issue.record("expected completion or error")
                    break
                }
            }
        }
    }

    @Test func sizeOverflow() throws {
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try drainChunks(
                "FFFFFFFFFFFFFFFF\r\n0\r\n\r\n"
            )
        }
    }

    @Test func controlByteInExtension() throws {
        var buffer = chunkBuffer("5;ext=a")
        buffer.writeBytes([0x01])
        buffer.writeString("b\r\nhello\r\n0\r\n\r\n")

        var state = WTHTTP1ChunkState()
        var copy = buffer
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try WTHTTP1Parser().parseChunk(
                from: &copy,
                state: &state
            )
        }
    }

    @Test func chunkLineTooLong() throws {
        let parser = WTHTTP1Parser(
            maxHeadBytes: 65536,
            maxHeaders: 256,
            maxChunkLineBytes: 8
        )
        var buffer = chunkBuffer("1;ext=" + String(
            repeating: "x",
            count: 64
        ))

        var state = WTHTTP1ChunkState()
        #expect(
            throws: WTHTTP1ParseError.badChunkFraming
        ) {
            _ = try parser.parseChunk(
                from: &buffer,
                state: &state
            )
        }
    }
}
