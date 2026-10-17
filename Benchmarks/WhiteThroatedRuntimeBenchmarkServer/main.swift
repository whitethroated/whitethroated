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

let environment = ProcessInfo.processInfo.environment
let host = environment["WHITETHROATED_HOST"] ?? "127.0.0.1"
let port = Int(
    environment["WHITETHROATED_PORT"] ?? "3000"
) ?? 3000
let eventLoopThreads = Int(
    environment["WHITETHROATED_THREADS"] ?? ""
)

private func fixedPrepared(
    status: HTTPResponseStatus,
    body: String?
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
            value: "text/plain; charset=utf-8"
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
private let notFoundStorage = fixedPrepared(
    status: .notFound,
    body: "Not Found"
)

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
            if head.uri == "/" {
                return .prepared(emptyOK)
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
        maxRequestBodyBytes: 16 * 1024 * 1024
    ),
    dispatcher: dispatcher
)

let channel = try server.start(
    host: host,
    port: port
)
try channel.closeFuture.wait()
