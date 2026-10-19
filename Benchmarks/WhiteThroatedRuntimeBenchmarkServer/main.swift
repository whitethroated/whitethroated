import Foundation
import NIOCore
import NIOHTTP1
import WhiteThroatedRuntime

// Independent runtime benchmark server. Exercises
// WhiteThroatedRuntime directly: no Application, no framework
// Router, no middleware, no Request/Response types. Same
// externally observable contract as the framework and raw-NIO
// benchmark servers:
//
//   GET /          -> empty 200
//   GET /user/:id  -> echo :id as text/plain
//   POST /user     -> empty 200
//   GET /json      -> small JSON as application/json
//   GET /response-stream-* -> opt-in response-stream controls

let environment = ProcessInfo.processInfo.environment
let host = environment["WHITETHROATED_HOST"] ?? "127.0.0.1"
let port = Int(
    environment["WHITETHROATED_PORT"] ?? "3000"
) ?? 3000
let eventLoopThreads = Int(
    environment["WHITETHROATED_THREADS"] ?? ""
)
let responseStreamBenchmarks =
    environment[
        "WHITETHROATED_RESPONSE_STREAM_BENCHMARKS"
    ] == "1"

private func fixedPrepared(
    status: HTTPResponseStatus,
    body: String?,
    contentType: String = "text/plain; charset=utf-8"
) -> RuntimePreparedResponse {
    var headers = HTTPHeaders()
    var bodyBuffer: ByteBuffer?

    if let body {
        var buffer = ByteBufferAllocator().buffer(
            capacity: body.utf8.count
        )
        buffer.writeString(body)
        headers.add(
            name: "content-type",
            value: contentType
        )
        headers.add(
            name: "content-length",
            value: String(buffer.readableBytes)
        )
        bodyBuffer = buffer
    } else {
        headers.add(
            name: "content-length",
            value: "0"
        )
    }

    return RuntimePreparedResponse(
        status: status,
        headers: headers,
        bodyBuffer: bodyBuffer
    )
}

private func paramHead(
    length: Int
) -> HTTPResponseHead {
    var headers = HTTPHeaders()
    headers.add(
        name: "content-type",
        value: "text/plain; charset=utf-8"
    )
    headers.add(
        name: "content-length",
        value: String(length)
    )

    return HTTPResponseHead(
        version: .http1_1,
        status: .ok,
        headers: headers
    )
}

private let paramHeadCache: [HTTPResponseHead] =
    (0...64).map { paramHead(length: $0) }

private let emptyOK = fixedPrepared(
    status: .ok,
    body: nil
)
private let jsonOK = fixedPrepared(
    status: .ok,
    body: #"{"message":"Hello, World!"}"#,
    contentType: "application/json; charset=utf-8"
)
private let notFoundStorage = fixedPrepared(
    status: .notFound,
    body: "Not Found"
)

private let streamKnownHeaders: HTTPHeaders = {
    var headers = HTTPHeaders()
    headers.add(
        name: "content-type",
        value: "text/plain; charset=utf-8"
    )
    headers.add(name: "content-length", value: "13")
    headers.add(
        name: "date",
        value: "Thu, 01 Jan 1970 00:00:00 GMT"
    )
    return headers
}()

private let streamChunkedHeaders: HTTPHeaders = {
    var headers = HTTPHeaders()
    headers.add(
        name: "content-type",
        value: "text/plain; charset=utf-8"
    )
    headers.add(
        name: "date",
        value: "Thu, 01 Jan 1970 00:00:00 GMT"
    )
    return headers
}()

private func streamResponse(
    knownLength: Bool,
    flushFirstChunk: Bool
) -> RuntimeResponse {
    RuntimeResponse(
        status: .ok,
        headers: knownLength
            ? streamKnownHeaders
            : streamChunkedHeaders,
        body: .stream(
            RuntimeResponseStream(
                produce: { writer in
                    if flushFirstChunk {
                        return writer
                            .writeStringAndFlush(
                                "Hello, "
                            ).flatMap {
                                writer.writeString(
                                    "World!"
                                )
                            }
                    }

                    return writer
                        .writeString("Hello, ")
                        .flatMap {
                            writer.writeString(
                                "World!"
                            )
                        }
                },
                expectedContentLength:
                    knownLength ? 13 : nil
            )
        ),
        contentLengthIsNormalized: knownLength
    )
}

private let userPrefix = "/user/"
private let userPrefixLength = 6

private func userIdentifier(
    from uri: String
) -> String? {
    guard uri.hasPrefix(userPrefix) else {
        return nil
    }

    let identifier = String(
        uri.dropFirst(userPrefixLength)
    )

    guard !identifier.isEmpty else {
        return nil
    }

    for byte in identifier.utf8 {
        if byte == 47 || byte == 63 {
            return nil
        }
    }

    return identifier
}

private let dispatcher = RuntimeDispatcher(
    hasMiddleware: false,
    hasStreamingRoutes: false,
    hasStreamingRoute: { _ in false },
    lookup: { head in
        switch head.method {
        case .GET:
            if responseStreamBenchmarks {
                switch head.uri {
                case "/response-stream-known":
                    return .sync(
                        RuntimeSyncAction { _ in
                            streamResponse(
                                knownLength: true,
                                flushFirstChunk: false
                            )
                        }
                    )

                case "/response-stream":
                    return .sync(
                        RuntimeSyncAction { _ in
                            streamResponse(
                                knownLength: false,
                                flushFirstChunk: false
                            )
                        }
                    )

                case "/response-stream-flush":
                    return .sync(
                        RuntimeSyncAction { _ in
                            streamResponse(
                                knownLength: false,
                                flushFirstChunk: true
                            )
                        }
                    )

                default:
                    break
                }
            }

            if head.uri == "/" {
                return .prepared(emptyOK)
            }

            if head.uri == "/json" {
                return .prepared(jsonOK)
            }

            if head.uri.hasPrefix(userPrefix) {
                return .sync(
                    RuntimeSyncAction { request in
                        guard
                            let identifier =
                                userIdentifier(
                                    from: request
                                        .head
                                        .uri
                                )
                        else {
                            return RuntimeResponse(
                                status: .notFound,
                                headers:
                                    notFoundStorage
                                    .headers,
                                body: .text(
                                    "Not Found"
                                ),
                                contentLengthIsNormalized:
                                    true
                            )
                        }

                        let length =
                            identifier.utf8.count

                        if length <= 64 {
                            return RuntimeResponse(
                                status: .ok,
                                headers:
                                    paramHeadCache[
                                        length
                                    ].headers,
                                body: .text(
                                    identifier
                                ),
                                contentLengthIsNormalized:
                                    true,
                                canonicalHead:
                                    paramHeadCache[
                                        length
                                    ],
                                canonicalBodyLength:
                                    length
                            )
                        }

                        return RuntimeResponse(
                            status: .ok,
                            headers: paramHead(
                                length: length
                            ).headers,
                            body: .text(
                                identifier
                            ),
                            contentLengthIsNormalized:
                                true
                        )
                    }
                )
            }

        case .POST:
            if head.uri == "/user" {
                return .prepared(emptyOK)
            }

        default:
            break
        }

        return .prepared(notFoundStorage)
    },
    dispatchPipeline: { _, _ in
        .prepared(notFoundStorage)
    },
    mapError: { _, _, _ in
        .response(
            RuntimeResponse(
                status: .internalServerError,
                headers: HTTPHeaders(),
                body: .text(
                    "Internal Server Error"
                )
            )
        )
    },
    notFound: notFoundStorage,
    payloadTooLarge: fixedPrepared(
        status: .payloadTooLarge,
        body: "Payload Too Large"
    ),
    expectationFailed: fixedPrepared(
        status: .expectationFailed,
        body: "Expectation Failed"
    ),
    internalServerError: fixedPrepared(
        status: .internalServerError,
        body: "Internal Server Error"
    )
)

let server = RuntimeServer(
    configuration: RuntimeServerConfiguration(
        eventLoopThreads: eventLoopThreads,
        maxRequestBodyBytes: 16 * 1024 * 1024,
        useTier1HTTP1: environment[
            "WHITETHROATED_TIER1_HTTP1"
        ] != "0"
    ),
    dispatcher: dispatcher
)

let channel = try server.start(
    host: host,
    port: port
)
try channel.closeFuture.wait()
