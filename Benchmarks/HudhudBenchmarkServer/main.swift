import Foundation
import Hudhud

let environment = ProcessInfo.processInfo.environment
let host = environment["HUDHUD_HOST"] ?? "127.0.0.1"
let port = Int(
    environment["HUDHUD_PORT"] ?? "3000"
) ?? 3000
let eventLoopThreads = Int(
    environment["HUDHUD_THREADS"] ?? ""
)

let app = Application(
    configuration: ServerConfiguration(
        maxRequestBodyBytes: 16 * 1024 * 1024,
        eventLoopThreads: eventLoopThreads
    )
)

let fastMiddlewareLayers = Int(
    environment["HUDHUD_FAST_MIDDLEWARE_LAYERS"] ?? "0"
) ?? 0
let asyncMiddlewareLayers = Int(
    environment["HUDHUD_ASYNC_MIDDLEWARE_LAYERS"] ?? "0"
) ?? 0

for _ in 0..<fastMiddlewareLayers {
    app.useFast { request, _, next in
        next(request)
    }
}

for _ in 0..<asyncMiddlewareLayers {
    app.use { request, _, next in
        next(request)
    }
}

final class StreamingUploadState: @unchecked Sendable {
    var bytes = 0
}

let benchmarkDate = "Thu, 01 Jan 1970 00:00:00 GMT"

let hello = PreparedResponse
    .text("Hello, World!")
    .header("date", benchmarkDate)

let ok = PreparedResponse
    .text("ok")
    .header("date", benchmarkDate)

app.get(
    "/prepared",
    response: hello
)

app.get("/plaintext") { _ in
    Response
        .text("Hello, World!")
        .header("date", benchmarkDate)
}

app.get("/json") { _ in
    .json(#"{"message":"Hello, World!"}"#)
}

app.get("/concurrent") { _ async throws in
    Response
        .text("Hello, World!")
        .header("date", benchmarkDate)
}

if environment["HUDHUD_RESPONSE_STREAM_BENCHMARKS"] == "1" {
    app.get("/response-stream-known") { _ in
        Response
            .stream(
                contentType: "text/plain; charset=utf-8"
            ) { writer in
                writer.writeString("Hello, ").flatMap {
                    writer.writeString("World!")
                }
            }
            .header("content-length", "13")
            .header("date", benchmarkDate)
    }

    app.get("/response-stream") { _ in
        Response
            .stream(
                contentType: "text/plain; charset=utf-8"
            ) { writer in
                writer.writeString("Hello, ").flatMap {
                    writer.writeString("World!")
                }
            }
            .header("date", benchmarkDate)
    }

    app.get("/response-stream-flush") { _ in
        Response
            .stream(
                contentType: "text/plain; charset=utf-8"
            ) { writer in
                writer.writeStringAndFlush(
                    "Hello, "
                ).flatMap {
                    writer.writeString("World!")
                }
            }
            .header("date", benchmarkDate)
    }
}

app.post("/aggregate-upload") { request in
    .text(
        String(request.body.readableBytes)
    )
}

app.postStream(
    "/stream-upload",
    maxBodyBytes: 16 * 1024 * 1024
) { _, context in
    let state = StreamingUploadState()

    return BodyStreamConsumer(
        onChunk: { chunk in
            state.bytes += chunk.readableBytes
            return nil
        },
        onEnd: {
            context.eventLoop.makeSucceededFuture(
                .text(String(state.bytes))
            )
        }
    )
}

app.get("/query") { request in
    .text(request.query("q") ?? "")
}

if environment["HUDHUD_UPLOAD_BENCHMARKS"] == "1" {
    app.post("/upload-aggregated") { _ in
        .text("ok")
    }

    app.postStream(
        "/upload-stream",
        maxBodyBytes: 8 * 1024 * 1024
    ) { _, context in
        BodyStreamConsumer(
            onChunk: { _ in nil },
            onEnd: {
                .text("ok")
            }
        )
    }
}

app.get("/users/:id") { request in
    .text(request.parameter("id") ?? "")
}

app.get("/users/:id/posts/:post") { request in
    let id = request.parameter("id") ?? ""
    let post = request.parameter("post") ?? ""

    return .text("\(id):\(post)")
}

if environment["HUDHUD_ROUTER_BENCHMARKS"] == "1" {
    for depth in [1, 4, 8, 16] {
        let suffix = (1...depth)
            .map { "s\($0)" }
            .joined(separator: "/")

        app.get(
            "/depth/\(suffix)",
            response: ok
        )
    }

    for count in [16, 256, 4_096] {
        for index in 0..<count {
            app.get(
                "/fanout/\(count)/r\(index)",
                response: ok
            )
        }
    }

    app.get(
        "/dynamic/a/:p1",
        response: ok
    )

    app.get(
        "/dynamic/a/:p1/b/:p2",
        response: ok
    )

    app.get(
        "/dynamic/a/:p1/b/:p2/c/:p3/d/:p4",
        response: ok
    )
}

try app.run(host: host, port: port)
