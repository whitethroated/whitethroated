import Testing

import NIOCore
import NIOEmbedded
import NIOHTTP1

@testable import WhiteThroatedHTTP1

/// Byte-exact oracle: identical logical responses through the stock
/// NIO encoder (full server pipeline, so HEAD/CONNECT suppression and
/// framing repair all engage) and `WTHTTP1ResponseWriter` must produce
/// identical wire bytes.
private final class WTWriterProbeSink: ChannelInboundHandler,
    RemovableChannelHandler
{
    typealias InboundIn = HTTPServerRequestPart

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {}
}

private struct WTWriterDifferentialCase {
    var name: String
    var requestMethodLine: String
    var requestMethod: WTHTTP1Method
    var status: HTTPResponseStatus
    var statusCode: Int
    var reason: String
    var headers: [(String, String)]
    var version: HTTPVersion
    var wtVersion: WTHTTP1Version
    var contentLength: Int?
    var body: String?
}

private func nioWriterBytes(
    _ testCase: WTWriterDifferentialCase
) throws -> [UInt8] {
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations
        .configureHTTPServerPipeline(
            withPipeliningAssistance: true,
            withErrorHandling: true
        )
    try channel.pipeline.syncOperations.addHandler(
        WTWriterProbeSink()
    )

    var request = channel.allocator.buffer(capacity: 64)
    request.writeString(
        testCase.requestMethodLine + " / HTTP/1.1\r\n\r\n"
    )
    try channel.writeInbound(request)

    let head = HTTPResponseHead(
        version: testCase.version,
        status: testCase.status,
        headers: HTTPHeaders(testCase.headers)
    )
    try channel.writeOutbound(
        HTTPServerResponsePart.head(head)
    )

    // The NIO encoder fails body parts for bodyless responses and
    // for HEAD/CONNECT responses, so those are withheld on the NIO
    // side only; the WT side still receives the body to prove its own
    // suppression by byte comparison.
    let nioAcceptsBody =
        testCase.status.mayHaveResponseBody
        && testCase.requestMethod != .connect
        && testCase.requestMethod != .head

    if nioAcceptsBody, let body = testCase.body {
        var bodyBuffer = channel.allocator.buffer(
            capacity: body.utf8.count
        )
        bodyBuffer.writeString(body)
        try channel.writeOutbound(
            HTTPServerResponsePart.body(
                .byteBuffer(bodyBuffer)
            )
        )
    }

    // Interim 1xx responses carry no end marker.
    if testCase.statusCode >= 200 {
        try channel.writeOutbound(
            HTTPServerResponsePart.end(nil)
        )
    }

    var out: [UInt8] = []
    while let chunk = try channel.readOutbound(
        as: ByteBuffer.self
    ) {
        out += chunk.readableBytesView
    }

    return out
}

private func wtWriterBytes(
    _ testCase: WTWriterDifferentialCase
) -> [UInt8]? {
    let head = WTHTTP1ResponseHead(
        statusCode: testCase.statusCode,
        reasonBytes: Array(testCase.reason.utf8),
        headers: testCase.headers.map {
            (Array($0.utf8), Array($1.utf8))
        }
    )

    var body: ByteBuffer?
    if let text = testCase.body {
        var buffer = ByteBufferAllocator().buffer(
            capacity: text.utf8.count
        )
        buffer.writeString(text)
        body = buffer
    }

    var out = ByteBufferAllocator().buffer(capacity: 256)
    guard
        WTHTTP1ResponseWriter.write(
            head: head,
            version: testCase.wtVersion,
            keepAlive: true,
            mayHaveBody: testCase.status.mayHaveResponseBody,
            requestMethod: testCase.requestMethod,
            contentLength: testCase.contentLength,
            body: body,
            into: &out
        )
    else {
        return nil
    }

    return Array(out.readableBytesView)
}

@Suite struct WTHTTP1WriterDifferentialTests {
    @Test func wireBytesMatchNIOEncoder() throws {
        let cases: [WTWriterDifferentialCase] = [
            WTWriterDifferentialCase(
                name: "empty-200",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [("content-length", "0")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 0,
                body: nil
            ),
            WTWriterDifferentialCase(
                name: "text-42",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [
                    (
                        "content-type",
                        "text/plain; charset=utf-8"
                    ),
                    ("content-length", "2"),
                ],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 2,
                body: "42"
            ),
            WTWriterDifferentialCase(
                name: "auto-chunked",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: nil,
                body: "hello"
            ),
            WTWriterDifferentialCase(
                name: "204-strips",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .noContent,
                statusCode: 204,
                reason: "No Content",
                headers: [("content-length", "5")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 0,
                body: "hello"
            ),
            WTWriterDifferentialCase(
                name: "304-strips-cl-keeps-etag",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .notModified,
                statusCode: 304,
                reason: "Not Modified",
                headers: [
                    ("content-length", "5"),
                    ("etag", "\"x\""),
                ],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 0,
                body: "hello"
            ),
            WTWriterDifferentialCase(
                name: "head-suppresses-body",
                requestMethodLine: "HEAD",
                requestMethod: .head,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [("content-length", "2")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 2,
                body: "42"
            ),
            WTWriterDifferentialCase(
                name: "connect-strips",
                requestMethodLine: "CONNECT",
                requestMethod: .connect,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [("content-length", "2")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 2,
                body: "42"
            ),
            WTWriterDifferentialCase(
                name: "custom-299",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .custom(
                    code: 299,
                    reasonPhrase: "Custom OK"
                ),
                statusCode: 299,
                reason: "Custom OK",
                headers: [("content-length", "3")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 3,
                body: "abc"
            ),
            WTWriterDifferentialCase(
                name: "custom-99-unpadded",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .custom(
                    code: 99,
                    reasonPhrase: "Weird"
                ),
                statusCode: 99,
                reason: "Weird",
                headers: [("content-length", "0")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 0,
                body: nil
            ),
            WTWriterDifferentialCase(
                name: "interim-103",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .custom(
                    code: 103,
                    reasonPhrase: "Early Hints"
                ),
                statusCode: 103,
                reason: "Early Hints",
                headers: [("link", "</x>")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 0,
                body: nil
            ),
            WTWriterDifferentialCase(
                name: "http10-keepalive",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [
                    ("content-length", "0"),
                    ("connection", "keep-alive"),
                ],
                version: .http1_0,
                wtVersion: .http10,
                contentLength: 0,
                body: nil
            ),
            WTWriterDifferentialCase(
                name: "duplicates-case-preserved",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [
                    ("X-A", "1"),
                    ("x-a", "2"),
                    ("content-length", "0"),
                ],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 0,
                body: nil
            ),
            WTWriterDifferentialCase(
                name: "te-removed-when-length-known",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .ok,
                statusCode: 200,
                reason: "OK",
                headers: [
                    ("content-length", "2"),
                    ("transfer-encoding", "chunked"),
                ],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 2,
                body: "42"
            ),
            WTWriterDifferentialCase(
                name: "empty-reason",
                requestMethodLine: "GET",
                requestMethod: .get,
                status: .custom(code: 299, reasonPhrase: ""),
                statusCode: 299,
                reason: "",
                headers: [("content-length", "0")],
                version: .http1_1,
                wtVersion: .http11,
                contentLength: 0,
                body: nil
            ),
        ]

        for testCase in cases {
            let nio = try nioWriterBytes(testCase)
            let wt = try #require(
                wtWriterBytes(testCase),
                "\(testCase.name): writer rejected valid input"
            )
            #expect(
                nio == wt,
                "\(testCase.name): nio=\(String(decoding: nio, as: UTF8.self).debugDescription) wt=\(String(decoding: wt, as: UTF8.self).debugDescription)"
            )
        }
    }
}
