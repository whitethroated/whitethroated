import Testing

import NIOCore

@testable import WhiteThroatedHTTP1

private func responseHead(
    statusCode: Int = 200,
    reason: String = "OK",
    headers: [(String, String)] = []
) -> WTHTTP1ResponseHead {
    WTHTTP1ResponseHead(
        statusCode: statusCode,
        reasonBytes: Array(reason.utf8),
        headers: headers.map {
            (Array($0.utf8), Array($1.utf8))
        }
    )
}

private func bodyBuffer(
    _ string: String
) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(
        capacity: string.utf8.count
    )
    buffer.writeString(string)
    return buffer
}

private func writtenBytes(
    head: WTHTTP1ResponseHead,
    version: WTHTTP1Version = .http11,
    keepAlive: Bool = true,
    mayHaveBody: Bool = true,
    requestMethod: WTHTTP1Method = .get,
    contentLength: Int? = 0,
    body: ByteBuffer? = nil
) -> [UInt8]? {
    var out = ByteBufferAllocator().buffer(capacity: 256)
    guard
        WTHTTP1ResponseWriter.write(
            head: head,
            version: version,
            keepAlive: keepAlive,
            mayHaveBody: mayHaveBody,
            requestMethod: requestMethod,
            contentLength: contentLength,
            body: body,
            into: &out
        )
    else {
        return nil
    }

    return Array(out.readableBytesView)
}

private func writtenString(
    head: WTHTTP1ResponseHead,
    version: WTHTTP1Version = .http11,
    keepAlive: Bool = true,
    mayHaveBody: Bool = true,
    requestMethod: WTHTTP1Method = .get,
    contentLength: Int? = 0,
    body: ByteBuffer? = nil,
    trustFraming: Bool = false
) -> String? {
    var out = ByteBufferAllocator().buffer(capacity: 256)
    guard
        WTHTTP1ResponseWriter.write(
            head: head,
            version: version,
            keepAlive: keepAlive,
            mayHaveBody: mayHaveBody,
            requestMethod: requestMethod,
            contentLength: contentLength,
            body: body,
            trustFraming: trustFraming,
            into: &out
        )
    else {
        return nil
    }

    return String(
        decoding: out.readableBytesView,
        as: UTF8.self
    )
}

@Suite struct WTHTTP1ResponseWriterTests {
    @Test func empty200Shape() throws {
        let text = try #require(
            writtenString(head: responseHead())
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        )
    }

    @Test func textBodyShape() throws {
        let text = try #require(
            writtenString(
                head: responseHead(
                    headers: [(
                        "content-type",
                        "text/plain; charset=utf-8"
                    )]
                ),
                contentLength: 2,
                body: bodyBuffer("42")
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 2\r\n\r\n42"
        )
    }

    @Test func wrongContentLengthRepaired() throws {
        let text = try #require(
            writtenString(
                head: responseHead(
                    headers: [
                        ("x-a", "1"),
                        ("content-length", "999"),
                        ("x-b", "2"),
                    ]
                ),
                contentLength: 2,
                body: bodyBuffer("42")
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\nx-a: 1\r\nx-b: 2\r\ncontent-length: 2\r\n\r\n42"
        )
    }

    @Test func transferEncodingRemovedWhenLengthKnown() throws {
        let text = try #require(
            writtenString(
                head: responseHead(
                    headers: [
                        ("transfer-encoding", "chunked")
                    ]
                ),
                contentLength: 0
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        )
    }

    @Test func trustedFramingPassesThroughUntouched() throws {
        let trusted = try #require(
            writtenString(
                head: responseHead(
                    headers: [
                        ("content-length", "2")
                    ]
                ),
                contentLength: 2,
                body: bodyBuffer("42"),
                trustFraming: true
            )
        )
        let repaired = try #require(
            writtenString(
                head: responseHead(
                    headers: [
                        ("content-length", "2")
                    ]
                ),
                contentLength: 2,
                body: bodyBuffer("42")
            )
        )
        #expect(trusted == repaired)
        #expect(
            trusted
                == "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n42"
        )
    }

    @Test func trustedFramingStillStripsBodyless() throws {
        let text = try #require(
            writtenString(
                head: responseHead(
                    statusCode: 204,
                    reason: "No Content",
                    headers: [
                        ("content-length", "5")
                    ]
                ),
                mayHaveBody: false,
                contentLength: 0,
                trustFraming: true
            )
        )
        #expect(
            text == "HTTP/1.1 204 No Content\r\n\r\n"
        )
    }

    @Test func trustedFramingWithoutLengthFallsBack() throws {
        let text = try #require(
            writtenString(
                head: responseHead(),
                contentLength: nil,
                body: bodyBuffer("hi"),
                trustFraming: true
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n"
        )
    }

    @Test func bodylessStatusStripsFraming() throws {
        for code in [204, 304] {
            let text = try #require(
                writtenString(
                    head: responseHead(
                        statusCode: code,
                        reason: code == 204
                            ? "No Content" : "Not Modified",
                        headers: [
                            ("content-length", "5"),
                            ("transfer-encoding", "chunked"),
                            ("etag", "\"x\""),
                        ]
                    ),
                    mayHaveBody: false,
                    contentLength: 0,
                    body: bodyBuffer("hello")
                ),
                "status \(code) must serialize"
            )
            #expect(
                !text.contains("content-length"),
                "status \(code) must strip CL on the wire"
            )
            #expect(
                !text.contains("transfer-encoding"),
                "status \(code) must strip TE on the wire"
            )
            #expect(text.contains("etag: \"x\""))
            #expect(!text.contains("hello"))
        }
    }

    @Test func headRequestSuppressesBodyKeepsFraming() throws {
        let text = try #require(
            writtenString(
                head: responseHead(
                    headers: [("content-type", "text/plain")]
                ),
                requestMethod: .head,
                contentLength: 2,
                body: bodyBuffer("42")
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 2\r\n\r\n"
        )
    }

    @Test func connectRequestStripsFramingAndBody() throws {
        let text = try #require(
            writtenString(
                head: responseHead(
                    headers: [("content-length", "2")]
                ),
                requestMethod: .connect,
                contentLength: 2,
                body: bodyBuffer("42")
            )
        )
        #expect(text == "HTTP/1.1 200 OK\r\n\r\n")
    }

    @Test func closeReplacesConnection() throws {
        let text = try #require(
            writtenString(
                head: responseHead(
                    headers: [
                        ("connection", "keep-alive"),
                        ("x-a", "1"),
                    ]
                ),
                keepAlive: false
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\nx-a: 1\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        )
    }

    @Test func http10KeepAliveAdvertised() throws {
        let text = try #require(
            writtenString(
                head: responseHead(),
                version: .http10,
                keepAlive: true
            )
        )
        #expect(
            text
                == "HTTP/1.0 200 OK\r\ncontent-length: 0\r\nconnection: keep-alive\r\n\r\n"
        )
    }

    @Test func http10CloseOmitsKeepAlive() throws {
        let text = try #require(
            writtenString(
                head: responseHead(),
                version: .http10,
                keepAlive: false
            )
        )
        #expect(
            text
                == "HTTP/1.0 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        )
    }

    @Test func chunkedSingleBufferEmission() throws {
        let text = try #require(
            writtenString(
                head: responseHead(),
                contentLength: nil,
                body: bodyBuffer("hello")
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        )
    }

    @Test func chunkedEmptyBodyEmitsTerminatorOnly() throws {
        let text = try #require(
            writtenString(
                head: responseHead(),
                contentLength: nil
            )
        )
        #expect(
            text
                == "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n0\r\n\r\n"
        )
    }

    @Test func invalidNameRejected() throws {
        #expect(
            writtenString(
                head: responseHead(
                    headers: [("bad name", "v")]
                )
            ) == nil
        )
    }

    @Test func invalidValueRejected() throws {
        #expect(
            writtenString(
                head: responseHead(
                    headers: [("x-a", "a\r\nInjected: 1")]
                )
            ) == nil
        )
    }

    @Test func invalidReasonRejected() throws {
        #expect(
            writtenString(
                head: responseHead(
                    statusCode: 299,
                    reason: "Bad\r\nReason"
                )
            ) == nil
        )
    }

    @Test func continueBytes() throws {
        var out = ByteBufferAllocator().buffer(capacity: 32)
        WTHTTP1ResponseWriter.writeContinue(into: &out)
        #expect(
            out.readString(length: out.readableBytes)
                == "HTTP/1.1 100 Continue\r\n\r\n"
        )
    }

    @Test func sealedEqualsGeneralPath() throws {
        let sealed = try #require(
            WTHTTP1ResponseSealer.seal(
                head: responseHead(
                    headers: [(
                        "content-type",
                        "text/plain; charset=utf-8"
                    )]
                ),
                version: .http11,
                keepAlive: true,
                mayHaveBody: true,
                contentLength: 2,
                body: bodyBuffer("42")
            )
        )

        var combined = ByteBufferAllocator().buffer(
            capacity: 256
        )
        var headCopy = sealed.headBytes
        var bodyCopy = sealed.bodyBytes
        combined.writeBuffer(&headCopy)
        combined.writeBuffer(&bodyCopy)

        let general = try #require(
            writtenBytes(
                head: responseHead(
                    headers: [(
                        "content-type",
                        "text/plain; charset=utf-8"
                    )]
                ),
                contentLength: 2,
                body: bodyBuffer("42")
            )
        )
        #expect(Array(combined.readableBytesView) == general)
    }

    @Test func sealedHeadServesHeadRequests() throws {
        let sealed = try #require(
            WTHTTP1ResponseSealer.seal(
                head: responseHead(),
                version: .http11,
                keepAlive: true,
                mayHaveBody: true,
                contentLength: 0,
                body: nil
            )
        )

        let headOnly = try #require(
            writtenBytes(
                head: responseHead(),
                requestMethod: .head,
                contentLength: 0
            )
        )
        #expect(
            Array(sealed.headBytes.readableBytesView)
                == headOnly
        )
        #expect(sealed.bodyBytes.readableBytes == 0)
    }

    @Test func sealedBodylessDropsBody() throws {
        let sealed = try #require(
            WTHTTP1ResponseSealer.seal(
                head: responseHead(
                    statusCode: 304,
                    reason: "Not Modified"
                ),
                version: .http11,
                keepAlive: true,
                mayHaveBody: false,
                contentLength: 0,
                body: bodyBuffer("hello")
            )
        )

        #expect(sealed.bodyBytes.readableBytes == 0)
    }

    @Test func sealedInvalidReturnsNil() throws {
        #expect(
            WTHTTP1ResponseSealer.seal(
                head: responseHead(
                    headers: [("x-a", "a\r\nb")]
                ),
                version: .http11,
                keepAlive: true,
                mayHaveBody: true,
                contentLength: 0,
                body: nil
            ) == nil
        )
    }
}
