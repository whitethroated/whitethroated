import Testing

import NIOCore

@testable import WhiteThroatedHTTP1

private func headBuffer(
    _ string: String
) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(
        capacity: string.utf8.count
    )
    buffer.writeString(string)
    return buffer
}

private func headBuffer(
    bytes: [UInt8]
) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(
        capacity: bytes.count
    )
    buffer.writeBytes(bytes)
    return buffer
}

private func parseHead(
    _ string: String,
    parser: WTHTTP1Parser = WTHTTP1Parser()
) throws -> WTHTTP1RequestHead? {
    var buffer = headBuffer(string)
    return try parser.parseHead(from: &buffer)
}

@Suite struct WTHTTP1ParserHeadTests {
    @Test func minimalGetNoHeaders() throws {
        let head = try #require(
            try parseHead("GET / HTTP/1.1\r\n\r\n")
        )

        #expect(head.method == .get)
        #expect(head.uriBytes() == Array("/".utf8))
        #expect(head.version == .http11)
        #expect(head.headerCount == 0)
        #expect(head.framing == .none)
        #expect(head.keepAlive)
        #expect(head.expectation == .none)
    }

    @Test func getWithHostHeader() throws {
        let head = try #require(
            try parseHead(
                "GET /user/42 HTTP/1.1\r\nHost: 127.0.0.1:3000\r\n\r\n"
            )
        )

        #expect(head.method == .get)
        #expect(
            head.uriBytes() == Array("/user/42".utf8)
        )
        #expect(head.headerCount == 1)
        #expect(
            head.headerName(at: 0) == Array("Host".utf8)
        )
        #expect(
            head.headerValue(at: 0)
                == Array("127.0.0.1:3000".utf8)
        )
        #expect(
            head.firstHeaderValue(
                named: Array("host".utf8)
            ) == Array("127.0.0.1:3000".utf8)
        )
        #expect(
            head.firstHeaderValue(
                named: Array("missing".utf8)
            ) == nil
        )
    }

    @Test func postContentLengthLeavesBodyReadable() throws {
        var buffer = headBuffer(
            "POST /user HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        )
        let head = try #require(
            try WTHTTP1Parser().parseHead(from: &buffer)
        )

        #expect(head.method == .post)
        #expect(head.framing == .contentLength(5))
        #expect(buffer.readableBytes == 5)
        #expect(
            buffer.getString(
                at: buffer.readerIndex,
                length: 5
            ) == "hello"
        )
    }

    @Test func postChunkedFraming() throws {
        let head = try #require(
            try parseHead(
                "POST /upload HTTP/1.1\r\nTransfer-Encoding: Chunked\r\n\r\n"
            )
        )

        #expect(head.framing == .chunked)
    }

    @Test func contentLengthZeroIsBodyless() throws {
        let head = try #require(
            try parseHead(
                "POST /user HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
            )
        )

        #expect(head.framing == .none)
    }

    @Test func http10DefaultsToClose() throws {
        let head = try #require(
            try parseHead("GET / HTTP/1.0\r\n\r\n")
        )

        #expect(head.version == .http10)
        #expect(!head.keepAlive)
    }

    @Test func http10KeepAliveToken() throws {
        let head = try #require(
            try parseHead(
                "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
            )
        )

        #expect(head.keepAlive)
    }

    @Test func http11CloseToken() throws {
        let head = try #require(
            try parseHead(
                "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
            )
        )

        #expect(!head.keepAlive)
    }

    @Test func closeBeatsKeepAlive() throws {
        let head = try #require(
            try parseHead(
                "GET / HTTP/1.1\r\nConnection: keep-alive, close\r\n\r\n"
            )
        )

        #expect(!head.keepAlive)
    }

    @Test func connectionTokensCaseInsensitive() throws {
        let head = try #require(
            try parseHead(
                "GET / HTTP/1.1\r\nConnection: ClOsE\r\n\r\n"
            )
        )

        #expect(!head.keepAlive)
    }

    @Test func expect100Continue() throws {
        let head = try #require(
            try parseHead(
                "POST /u HTTP/1.1\r\nContent-Length: 3\r\nExpect: 100-Continue\r\n\r\n"
            )
        )

        #expect(head.expectation == .continue100)
        #expect(head.framing == .contentLength(3))
    }

    @Test func expectOtherIsUnsupported() throws {
        let head = try #require(
            try parseHead(
                "POST /u HTTP/1.1\r\nExpect: 103-early\r\n\r\n"
            )
        )

        #expect(head.expectation == .unsupported)
    }

    @Test func expectOnHTTP10IsUnsupported() throws {
        let head = try #require(
            try parseHead(
                "POST /u HTTP/1.0\r\nExpect: 100-continue\r\n\r\n"
            )
        )

        #expect(head.expectation == .unsupported)
    }

    @Test func owsLeadingStrippedTrailingKept() throws {
        // Mirrors llhttp's observable value semantics exactly: the
        // framework downstream depends on byte-identical values.
        let head = try #require(
            try parseHead(
                "GET / HTTP/1.1\r\nX-A:\t  value\t \r\nX-B:\r\n\r\n"
            )
        )

        #expect(head.headerCount == 2)
        #expect(
            head.headerValue(at: 0)
                == Array("value\t ".utf8)
        )
        #expect(head.headerValue(at: 1) == [])
    }

    @Test func duplicateContentLengthRejected() throws {
        // Any duplicate is rejected, mirroring llhttp, even
        // byte-identical ones.
        for second in ["4", "5"] {
            #expect(
                throws: WTHTTP1ParseError.badContentLength,
                "duplicate 4/\(second) must fail"
            ) {
                _ = try parseHead(
                    "POST /u HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: \(second)\r\n\r\n"
                )
            }
        }
    }

    @Test func emptyTransferEncodingIgnored() throws {
        let head = try #require(
            try parseHead(
                "POST /u HTTP/1.1\r\nTransfer-Encoding:\r\n\r\n"
            )
        )

        #expect(head.framing == .none)
    }

    @Test func pipelinedHeadsConsumeExactly() throws {
        var buffer = headBuffer(
            "GET /a HTTP/1.1\r\n\r\nPOST /b HTTP/1.1\r\nContent-Length: 3\r\n\r\nxyz"
        )
        let parser = WTHTTP1Parser()

        let first = try #require(
            try parser.parseHead(from: &buffer)
        )
        #expect(first.uriBytes() == Array("/a".utf8))

        let second = try #require(
            try parser.parseHead(from: &buffer)
        )
        #expect(second.uriBytes() == Array("/b".utf8))
        #expect(second.framing == .contentLength(3))
        #expect(buffer.readableBytes == 3)
    }

    @Test func partialHeadNeedsMoreData() throws {
        var buffer = headBuffer("GET / HTTP/1.1\r\nHost: x")
        let before = buffer.readableBytes
        let head = try WTHTTP1Parser().parseHead(
            from: &buffer
        )

        #expect(head == nil)
        #expect(buffer.readableBytes == before)

        buffer.writeString(".com\r\n\r\n")
        let done = try #require(
            try WTHTTP1Parser().parseHead(from: &buffer)
        )
        #expect(done.headerCount == 1)
        #expect(buffer.readableBytes == 0)
    }

    @Test func emptyBufferNeedsMoreData() throws {
        var buffer = headBuffer("")
        #expect(
            try WTHTTP1Parser().parseHead(from: &buffer)
                == nil
        )
    }

    @Test func bareLFLineEndingsRejected() throws {
        #expect(
            throws: WTHTTP1ParseError.badRequestLine
        ) {
            _ = try parseHead("GET / HTTP/1.1\n\r\n")
        }

        #expect(
            throws: WTHTTP1ParseError.badHeaderLine
        ) {
            _ = try parseHead(
                "GET / HTTP/1.1\r\nHost: x\n\r\n"
            )
        }
    }

    @Test func trailingOWSAfterVersionRejected() throws {
        for suffix in [" ", "  ", "\t", " \t "] {
            #expect(
                throws: WTHTTP1ParseError.badRequestLine,
                "suffix \(suffix.debugDescription) must fail"
            ) {
                _ = try parseHead(
                    "GET / HTTP/1.1\(suffix)\r\n\r\n"
                )
            }
        }
    }

    @Test func repeatedSeparatorSpacesAccepted() throws {
        // llhttp skips runs of SP between the three request-line parts.
        for line in [
            "GET  / HTTP/1.1",
            "GET /  HTTP/1.1",
            "GET   /   HTTP/1.1",
        ] {
            let head = try #require(
                try parseHead(line + "\r\n\r\n"),
                "line \(line.debugDescription) must parse"
            )
            #expect(head.method == .get)
            #expect(head.uriBytes() == Array("/".utf8))
            #expect(head.version == .http11)
        }
    }

    @Test func customMethodKeepsBytes() throws {
        let head = try #require(
            try parseHead("PURGE /cache HTTP/1.1\r\n\r\n")
        )

        #expect(head.method == .purge)
    }

    @Test func unknownMethodRejected() throws {
        // llhttp has no custom-method production; stock rejects.
        for method in ["FOO", "get", "Get", "QUERY"] {
            #expect(
                throws: WTHTTP1ParseError.badRequestLine,
                "method \(method) must fail"
            ) {
                _ = try parseHead(
                    "\(method) /x HTTP/1.1\r\n\r\n"
                )
            }
        }
    }

    @Test func allKnownMethodsMatch() throws {
        let cases: [(String, WTHTTP1Method)] = [
            ("GET", .get), ("PUT", .put), ("ACL", .acl),
            ("HEAD", .head), ("POST", .post),
            ("COPY", .copy), ("LOCK", .lock),
            ("MOVE", .move), ("BIND", .bind),
            ("LINK", .link), ("PATCH", .patch),
            ("TRACE", .trace), ("MKCOL", .mkcol),
            ("MERGE", .merge), ("PURGE", .purge),
            ("NOTIFY", .notify), ("SEARCH", .search),
            ("UNLOCK", .unlock), ("REBIND", .rebind),
            ("UNBIND", .unbind), ("REPORT", .report),
            ("DELETE", .delete), ("UNLINK", .unlink),
            ("CONNECT", .connect), ("MSEARCH", .msearch),
            ("OPTIONS", .options),
            ("PROPFIND", .propfind),
            ("CHECKOUT", .checkout),
            ("PROPPATCH", .propatch),
            ("SUBSCRIBE", .subscribe),
            ("MKCALENDAR", .mkcalendar),
            ("MKACTIVITY", .mkactivity),
            ("UNSUBSCRIBE", .unsubscribe),
            ("SOURCE", .source),
        ]

        for (name, expected) in cases {
            let head = try #require(
                try parseHead("\(name) / HTTP/1.1\r\n\r\n"),
                "method \(name) must parse"
            )
            #expect(
                head.method == expected,
                "method \(name) must match"
            )
        }
    }

    @Test func uriFormsAccepted() throws {
        for uri in [
            "*", "/",
            "/a/b?c=d&e=f",
            "/pct/%41%42",
            "http://example.com/abs",
            "example.com:443",
        ] {
            let head = try #require(
                try parseHead("GET \(uri) HTTP/1.1\r\n\r\n"),
                "uri \(uri) must parse"
            )
            #expect(
                head.uriBytes() == Array(uri.utf8)
            )
        }
    }

    @Test func uriRejectsNonASCIIBytes() throws {
        // Mirrors llhttp: raw non-ASCII bytes must be percent-encoded.
        var buffer = headBuffer(
            bytes: Array("GET /caf".utf8) + [0xC3, 0xA9]
                + Array(" HTTP/1.1\r\n\r\n".utf8)
        )

        #expect(throws: WTHTTP1ParseError.badRequestLine) {
            _ = try WTHTTP1Parser().parseHead(from: &buffer)
        }
    }

    @Test func malformedRequestLines() throws {
        for line in [
            "GET",
            "GET ",
            "GET /",
            "GET / ",
            "GET / HTTP/1.1 EXTRA",
            "GET / HTTP/1.1 ",
            " GET / HTTP/1.1",
            "/ HTTP/1.1",
            "GET HTTP/1.1",
            "",
        ] {
            #expect(
                throws: WTHTTP1ParseError.badRequestLine,
                "line \(line.debugDescription) must fail"
            ) {
                _ = try parseHead(line + "\r\n\r\n")
            }
        }
    }

    @Test func uriRejectsSpacesAndControls() throws {
        for uri in [
            "/a b",
            "/a\tb",
            "/a\rb",
            "/a\u{7F}b",
        ] {
            #expect(
                throws: WTHTTP1ParseError.badRequestLine,
                "uri \(uri.debugDescription) must fail"
            ) {
                _ = try parseHead(
                    "GET \(uri) HTTP/1.1\r\n\r\n"
                )
            }
        }
    }

    @Test func unsupportedVersions() throws {
        for version in [
            "HTTP/2", "HTTP/1.2", "http/1.1", "HTTP/1",
            "HTTP/11", "HTTPS/1.1",
        ] {
            #expect(
                throws: WTHTTP1ParseError.unsupportedVersion,
                "version \(version) must fail"
            ) {
                _ = try parseHead(
                    "GET / \(version)\r\n\r\n"
                )
            }
        }
    }

    @Test func malformedHeaderLines() throws {
        for header in [
            "NoColonHere",
            ": empty-name",
            " : blank-name",
            "Name : spaced-colon",
            "Bad\u{1}Name: x",
            "X: bad\u{7F}value",
            "X: bad\u{0}value",
        ] {
            #expect(
                throws: WTHTTP1ParseError.badHeaderLine,
                "header \(header.debugDescription) must fail"
            ) {
                _ = try parseHead(
                    "GET / HTTP/1.1\r\n\(header)\r\n\r\n"
                )
            }
        }
    }

    @Test func obsFoldContinuationRejected() throws {
        #expect(
            throws: WTHTTP1ParseError.badHeaderLine
        ) {
            _ = try parseHead(
                "GET / HTTP/1.1\r\nX-A: one\r\n continued\r\n\r\n"
            )
        }
    }

    @Test func bareCRRejected() throws {
        var buffer = headBuffer(
            bytes: Array(
                "GET / HTTP/1.1\r\nX-A: on\re\r\n\r\n".utf8
            )
        )

        #expect(throws: WTHTTP1ParseError.badHeaderLine) {
            _ = try WTHTTP1Parser().parseHead(from: &buffer)
        }
    }

    @Test func malformedContentLength() throws {
        for value in [
            "abc", "", "12 3", "+12", "-1", "0x10", "1,000",
            "99999999999999999999999999999999",
        ] {
            #expect(
                throws: WTHTTP1ParseError.badContentLength,
                "content-length \(value) must fail"
            ) {
                _ = try parseHead(
                    "POST /u HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n"
                )
            }
        }
    }

    @Test func duplicateDifferingContentLength() throws {
        // Covered with identical duplicates in
        // duplicateContentLengthRejected; kept as the smuggling-shape
        // regression with a body attached.
        #expect(
            throws: WTHTTP1ParseError.badContentLength
        ) {
            _ = try parseHead(
                "POST /u HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nbody!"
            )
        }
    }

    @Test func contentLengthPlusTransferEncoding() throws {
        #expect(
            throws: WTHTTP1ParseError.ambiguousFraming
        ) {
            _ = try parseHead(
                "POST /u HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n"
            )
        }
    }

    @Test func unsupportedTransferEncodings() throws {
        for value in [
            "gzip", "chunked, gzip", "gzip, chunked",
            "identity", "chunked, chunked",
        ] {
            #expect(
                throws: WTHTTP1ParseError
                    .unsupportedTransferEncoding,
                "transfer-encoding \(value) must fail"
            ) {
                _ = try parseHead(
                    "POST /u HTTP/1.1\r\nTransfer-Encoding: \(value)\r\n\r\n"
                )
            }
        }
    }

    @Test func connectionUpgradeRoutedNormally() throws {
        // Stock pipeline without upgraders routes upgrade attempts as
        // normal requests (see WTHTTP1StockBehaviorTests); Tier 1
        // mirrors that and simply never performs a handshake.
        let head = try #require(
            try parseHead(
                "GET /ws HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"
            )
        )

        #expect(head.headerCount == 2)
        #expect(head.keepAlive)
        #expect(head.framing == .none)
    }

    @Test func tooManyHeaders() throws {
        let parser = WTHTTP1Parser(
            maxHeadBytes: 65536,
            maxHeaders: 2,
            maxChunkLineBytes: 4096
        )

        #expect(
            throws: WTHTTP1ParseError.tooManyHeaders
        ) {
            _ = try parseHead(
                "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n",
                parser: parser
            )
        }
    }

    @Test func defaultHeaderCountBoundary() throws {
        var ok = "GET / HTTP/1.1\r\n"
        for index in 0..<256 {
            ok += "X-H\(index): v\r\n"
        }
        ok += "\r\n"

        let head = try #require(try parseHead(ok))
        #expect(head.headerCount == 256)

        var over = "GET / HTTP/1.1\r\n"
        for index in 0..<257 {
            over += "X-H\(index): v\r\n"
        }
        over += "\r\n"

        #expect(
            throws: WTHTTP1ParseError.tooManyHeaders
        ) {
            _ = try parseHead(over)
        }
    }

    @Test func headTooLargeSmallLimit() throws {
        let parser = WTHTTP1Parser(
            maxHeadBytes: 32,
            maxHeaders: 256,
            maxChunkLineBytes: 4096
        )

        #expect(
            throws: WTHTTP1ParseError.headTooLarge
        ) {
            _ = try parseHead(
                "GET /a-longer-target HTTP/1.1\r\n\r\n",
                parser: parser
            )
        }
    }

    @Test func headTooLargeWithoutTerminator() throws {
        let parser = WTHTTP1Parser(
            maxHeadBytes: 32,
            maxHeaders: 256,
            maxChunkLineBytes: 4096
        )
        var buffer = headBuffer(
            String(repeating: "x", count: 64)
        )

        #expect(throws: WTHTTP1ParseError.headTooLarge) {
            _ = try parser.parseHead(from: &buffer)
        }
    }
}
