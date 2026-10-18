import Foundation
import Testing

import NIOCore
import NIOEmbedded
import NIOHTTP1

@testable import WhiteThroatedHTTP1

/// Differential oracle: every corpus input runs through both the stock
/// NIO HTTP decoder and `WTHTTP1Parser`. Matching accept/reject plus
/// matching head fields, keep-alive, and body bytes is required unless
/// the case is a documented intentional divergence (all in the strict
/// reject direction).
private struct NIODifferentialVerdict: Equatable {
    var outcome: String
}

private func nioVerdict(
    for bytes: [UInt8]
) -> NIODifferentialVerdict {
    do {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            ByteToMessageHandler(HTTPRequestDecoder())
        )

        var buffer = channel.allocator.buffer(
            capacity: bytes.count
        )
        buffer.writeBytes(bytes)
        try channel.writeInbound(buffer)

        var parts: [String] = []
        var body = channel.allocator.buffer(capacity: 0)
        while let part = try channel.readInbound(
            as: HTTPServerRequestPart.self
        ) {
            switch part {
            case .head(let head):
                let nioMethod: String
                switch head.method {
                case .RAW(let value):
                    nioMethod = "RAW(\(value))"

                default:
                    nioMethod = "\(head.method)"
                        .uppercased()
                }

                var summary = "head method=\(nioMethod)"
                summary += " uri=\(head.uri)"
                summary += " version=\(head.version)"
                summary += " keepAlive=\(head.isKeepAlive)"
                summary += " headers=["
                summary += head.headers.map {
                    "\($0.name):\($0.value)"
                }.joined(separator: ",")
                summary += "]"
                parts.append(summary)

            case .body(var chunk):
                body.writeBuffer(&chunk)

            case .end(let trailers):
                var copy = body
                let text = copy.readString(
                    length: copy.readableBytes
                ) ?? "<binary:\(copy.readableBytes)>"
                parts.append("body=\(text)")
                parts.append(
                    "trailers=\(trailers?.description ?? "none")"
                )
            }
        }

        try channel.finish()
        return NIODifferentialVerdict(
            outcome: "accept " + parts.joined(separator: " ")
        )
    } catch {
        return NIODifferentialVerdict(
            outcome: "error"
        )
    }
}

private func wtVerdict(
    for bytes: [UInt8],
    parser: WTHTTP1Parser = WTHTTP1Parser()
) -> NIODifferentialVerdict {
    do {
        var buffer = ByteBufferAllocator().buffer(
            capacity: bytes.count
        )
        buffer.writeBytes(bytes)

        guard
            let head = try parser.parseHead(from: &buffer)
        else {
            return NIODifferentialVerdict(
                outcome: "needMoreData"
            )
        }

        var methodText: String
        switch head.method {
        case .custom(let raw):
            methodText = "RAW(" + String(
                decoding: raw,
                as: UTF8.self
            ) + ")"

        default:
            methodText = "\(head.method)".uppercased()
        }

        var summary = "head method=\(methodText)"
        summary += " uri=" + String(
            decoding: head.uriBytes(),
            as: UTF8.self
        )
        summary += " version=" + (
            head.version == .http11 ? "HTTP/1.1" : "HTTP/1.0"
        )
        summary += " keepAlive=\(head.keepAlive)"
        summary += " headers=["
        summary += (0..<head.headerCount).map { index in
            String(
                decoding: head.headerName(at: index),
                as: UTF8.self
            ) + ":" + String(
                decoding: head.headerValue(at: index),
                as: UTF8.self
            )
        }.joined(separator: ",")
        summary += "]"

        var parts = [summary]
        switch head.framing {
        case .none:
            parts.append("body=")
            parts.append("trailers=none")

        case .contentLength(let length):
            guard buffer.readableBytes >= length else {
                return NIODifferentialVerdict(
                    outcome: "needMoreData"
                )
            }
            var body = buffer.readSlice(length: length)!
            let text = body.readString(
                length: body.readableBytes
            ) ?? "<binary>"
            parts.append("body=\(text)")
            parts.append("trailers=none")

        case .chunked:
            var state = WTHTTP1ChunkState()
            var body = ByteBufferAllocator().buffer(
                capacity: 0
            )
            while true {
                switch try parser.parseChunk(
                    from: &buffer,
                    state: &state
                ) {
                case .needMoreData:
                    return NIODifferentialVerdict(
                        outcome: "needMoreData"
                    )

                case .data(var slice):
                    body.writeBuffer(&slice)

                case .end:
                    let text = body.readString(
                        length: body.readableBytes
                    ) ?? "<binary>"
                    parts.append("body=\(text)")
                    parts.append("trailers=none")
                    return NIODifferentialVerdict(
                        outcome: "accept "
                            + parts.joined(separator: " ")
                    )
                }
            }
        }

        return NIODifferentialVerdict(
            outcome: "accept " + parts.joined(separator: " ")
        )
    } catch {
        return NIODifferentialVerdict(
            outcome: "error"
        )
    }
}

private func normalizeTrailers(
    _ verdict: NIODifferentialVerdict
) -> String {
    guard
        let range = verdict.outcome.range(
            of: "trailers="
        )
    else {
        return verdict.outcome
    }

    return String(verdict.outcome[..<range.lowerBound])
        + "trailers=none"
}

@Suite struct WTHTTP1DifferentialTests {
    @Test func corpusMatchesNIO() throws {
        // Discovery corpus. Every input must produce the identical
        // verdict on both decoders unless it is promoted to the
        // documented-divergence list below with a strictness reason.
        let inputs: [[UInt8]] = [
            Array("GET / HTTP/1.1\r\n\r\n".utf8),
            Array("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
                    .utf8
            ),
            Array("GET / HTTP/1.0\r\n\r\n".utf8),
            Array(
                "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n".utf8
            ),
            Array(
                "GET / HTTP/1.1\r\nConnection: close\r\n\r\n".utf8
            ),
            Array("HEAD /x HTTP/1.1\r\n\r\n".utf8),
            Array("OPTIONS * HTTP/1.1\r\n\r\n".utf8),
            Array("PURGE /cache HTTP/1.1\r\n\r\n".utf8),
            Array("FOO /x HTTP/1.1\r\n\r\n".utf8),
            Array("get /x HTTP/1.1\r\n\r\n".utf8),
            Array("GET  / HTTP/1.1\r\n\r\n".utf8),
            Array("GET / HTTP/1.1 \r\n\r\n".utf8),
            Array("GET / HTTP/2\r\n\r\n".utf8),
            Array(
                "GET / HTTP/1.1\r\nX-A: one\r\n continued\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\nbody".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 5\r\n\r\nbody!".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding:\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length:   5 \r\n\r\nhello".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8
            ),
            Array(
                "GET / HTTP/1.1\r\nX-Bad: a\u{1}b\r\n\r\n".utf8
            ),
            Array("GET /caf\u{C3}\u{A9} HTTP/1.1\r\n\r\n".utf8),
            Array("GET / HTTP/1.1\nHost: x\n\n".utf8),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5;e=1\r\nhello\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\nhello\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "GET / HTTP/1.1\r\nConnection: keep-alive, close\r\n\r\n"
                    .utf8
            ),
            Array(
                "GET / HTTP/1.1\r\nX-A:   padded  \r\nX-E:\r\nX-D: 1\r\nX-D: 2\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 5 x\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 12 3\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length:\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: Chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: CHUNKED\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked, chunked\r\n\r\n"
                    .utf8
            ),
            Array(" GET / HTTP/1.1\r\n\r\n".utf8),
            Array("GET /\tHTTP/1.1\r\n\r\n".utf8),
            Array("GET / HTTP/1.1\t\r\n\r\n".utf8),
            Array("GET / HTTP/1.1  \r\n\r\n".utf8),
            Array("GET   /   HTTP/1.1\r\n\r\n".utf8),
            Array(
                "GET /ws HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: identity\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked, identity\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: identity, chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding:\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked \r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: +12\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 0x10\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 1,000\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 00\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nContent-Length: 007\r\n\r\n1234567".utf8
            ),
            Array("GET / HTTP/1.1\r\nX-Bin: a".utf8) + [0xFF]
                + Array("b\r\n\r\n".utf8),
            Array("POST /u HTTP/1.1\r\nContent-Length: 5".utf8) + [0xFF]
                + Array("\r\n\r\n".utf8),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: identity\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding:\r\nTransfer-Encoding:\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: identity, identity, chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: Identity, Chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked, chunked, chunked\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: identity , chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked,\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: ,chunked\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\t\r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: \t chunked\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding:    \r\n\r\n".utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding:\r\n\r\n3\r\nbye\r\n0\r\n\r\n"
                    .utf8
            ),
            Array(
                "GET / HTTP/1.1\r\nConnection: close \r\n\r\n".utf8
            ),
            Array(
                "GET / HTTP/1.1\r\nConnection: keep-alive,\r\n\r\n".utf8
            ),
            Array(
                "GET / HTTP/1.1\r\nConnection: \r\n\r\n".utf8
            ),
        ]

        // Trailer-bearing bodies: framing and body bytes must match;
        // trailer VALUES are discarded by design, so the trailers
        // field is normalized before comparison.
        let trailerInputs: [[UInt8]] = [
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-T: v\r\n\r\n"
                    .utf8
            ),
            Array(
                "POST /u HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nbye\r\n0\r\nA: 1\r\nB: two\r\n\r\n"
                    .utf8
            ),
        ]

        for input in trailerInputs {
            let nio = nioVerdict(for: input)
            let wt = wtVerdict(for: input)
            let preview = String(
                decoding: input.prefix(72),
                as: UTF8.self
            )
            #expect(
                normalizeTrailers(nio) == normalizeTrailers(wt),
                "input \(preview.debugDescription): nio=\(nio.outcome) wt=\(wt.outcome)"
            )
        }

        for input in inputs {
            let nio = nioVerdict(for: input)
            let wt = wtVerdict(for: input)
            let preview = String(
                decoding: input.prefix(72),
                as: UTF8.self
            )
            #expect(
                nio == wt,
                "input \(preview.debugDescription): nio=\(nio.outcome) wt=\(wt.outcome)"
            )
        }
    }
}
