# Hudhud

Hudhud is an experimental high-performance web framework written entirely in Swift.

The project has two non-negotiable goals:

1. An ergonomic developer experience inspired by Express.js.
2. A low-overhead runtime architecture designed to push Swift server performance as far as practical.

Hudhud is pre-alpha. API compatibility is intentionally secondary to establishing a fast, measurable runtime architecture.

## Requirements

- Swift 6.4 is the development and benchmark toolchain.
- Swift Package Manager tools version 6.1 or newer.
- SwiftNIO 2.104.0, pinned exactly for reproducible builds.

## Quick start

```swift
import Hudhud

let app = Application()

app.get("/") { _ in
    .text("Hello from Hudhud")
}

app.get("/users/:id") { request in
    let id = request.parameter("id") ?? "unknown"
    let expand = request.query("expand") ?? "false"

    return .json(
        #"{"id":"\#(id)","expand":"\#(expand)"}"#
    )
}

try app.run(port: 3000)
```

## Catch-all routes

A terminal catch-all captures the remaining path without changing static or single-segment parameter precedence.

```swift
app.get("/files/*path") { request in
    .text(request.parameter("path") ?? "")
}
```

`/files/images/2026/avatar.png` produces `images/2026/avatar.png`.

Catch-all parameters must be the final route segment.

## Route groups

Route prefixes are composed during application setup, so groups add no extra request-time routing layer.

```swift
let api = app.group("/api")
let v1 = api.group("/v1")

v1.get("/health", response: .text("ok"))

v1.get("/users/:id") { request in
    .json(#"{"id":"\#(request.parameter("id") ?? "")"}"#)
}
```

## JSON

Hudhud supports lazy JSON request decoding and both dynamic and prepared Codable JSON responses.

```swift
struct User: Codable {
    let id: Int
    let name: String
}

app.post("/users") { request in
    guard let user = try? request.decodeJSON(User.self) else {
        return .text("Invalid JSON", status: .badRequest)
    }

    return (try? Response.json(user))
        ?? .internalServerError()
}
```

For immutable Codable payloads, encode once during setup:

```swift
let payload = try PreparedResponse.json(
    User(id: 1, name: "Hudhud")
)

app.get("/user", response: payload)
```

## Async/await routes

Swift concurrency is available as an opt-in route type:

```swift
app.get("/profile") { request async throws in
    let profile = try await loadProfile(
        id: request.parameter("id") ?? ""
    )

    return try Response.json(profile)
}
```

Async/await routes use SwiftNIO's `EventLoopPromise.completeWithTask` bridge. A `Task` is created only for a route registered with an async handler. Prepared, synchronous, and NIO-future handlers do not pay this cost.

For event-loop-native I/O where maximum throughput matters, the NIO future handler remains available:

```swift
app.get("/nio") { request, context in
    context.eventLoop.makeSucceededFuture(
        .text("ok")
    )
}
```

## URL-encoded forms

Aggregated request bodies can be read as `application/x-www-form-urlencoded` data without Foundation URL parsing:

```swift
app.post("/login") { request in
    let email = request.form("email") ?? ""
    let remember = request.form("remember") ?? "false"

    return .text("\(email):\(remember)")
}
```

`request.form(name)` scans lazily and stops at the requested field. `request.formParameters` materializes the full dictionary only when needed. Percent escapes and `+` spaces follow standard URL-encoded form semantics.

## Streaming request bodies

Large request bodies can opt into chunk streaming instead of whole-body aggregation:

```swift
final class UploadState: @unchecked Sendable {
    var bytes = 0
}

app.postStream(
    "/upload/:id",
    maxBodyBytes: 100 * 1024 * 1024
) { request, _ in
    let state = UploadState()

    return BodyStreamConsumer(
        onChunk: { chunk in
            state.bytes += chunk.readableBytes
        },
        onEnd: {
            .text(
                "received \(state.bytes) bytes"
            )
        }
    )
}
```

`StreamRequest` exposes method, URI, headers, route parameters, queries, and cookies, but intentionally does not expose an aggregated body.

The synchronous `onChunk` overload returns `Void` and does not allocate an `EventLoopFuture` per chunk. Use it for CPU-only processing, counters, incremental parsers, or sinks that complete synchronously.

For synchronous processing that can fail, use `onChunkThrowing:`. Errors enter Hudhud's normal streaming error path without allocating a future on successful chunks:

```swift
BodyStreamConsumer(
    onChunkThrowing: { chunk in
        try parser.consume(chunk)
    },
    onEnd: {
        .noContent()
    }
)
```

For asynchronous sinks, return an `EventLoopFuture<Void>` from `onChunk`:

```swift
onChunk: { chunk in
    fileWriter.write(chunk)
}
```

When a chunk future is returned, Hudhud pauses channel auto-read and resumes only after the future completes. Futures from another event loop are hopped back to the request event loop before channel state is touched.

Streaming routes support the normal middleware chain. If middleware short-circuits the request, Hudhud drains/discards the incoming body without invoking the stream consumer.

Available registration APIs include:

```swift
app.postStream(...)
app.putStream(...)
app.patchStream(...)
app.deleteStream(...)
app.onStream(.post, ...)
```

Route groups expose the same streaming APIs.

Ordinary routes keep the existing aggregation behavior and do not pay a streaming router lookup unless the same HTTP method has at least one streaming route.

Hudhud also handles `Expect: 100-continue` for large uploads. Accepted HTTP/1.1 requests receive an informational `100 Continue` immediately. If a declared `Content-Length` already exceeds the configured limit, Hudhud returns `413 Payload Too Large` and closes the connection without waiting for a body the client has not sent. Unsupported expectations receive `417 Expectation Failed`.


### Streaming multipart/form-data

Multipart uploads reuse the request-streaming path and do not require whole-body aggregation:

```swift
final class UploadState: @unchecked Sendable {
    var activePart: MultipartPart?
    var fileBytes = 0
}

app.onError { error, _ in
    if error is MultipartFormDataError {
        return .text(
            "Invalid multipart body",
            status: .badRequest
        )
    }

    return .internalServerError()
}

app.postStream(
    "/upload",
    maxBodyBytes: 100 * 1024 * 1024
) { request, _ in
    let state = UploadState()

    do {
        return try BodyStreamConsumer.multipart(
            request: request,
            onEvent: { event in
                switch event {
                case .partBegin(let part):
                    state.activePart = part

                case .partBody(let chunk):
                    if state.activePart?.isFile == true {
                        state.fileBytes +=
                            chunk.readableBytes
                    }

                case .partEnd:
                    state.activePart = nil
                }
            },
            onEnd: {
                .text(
                    "received \(state.fileBytes) file bytes"
                )
            }
        )
    } catch {
        return BodyStreamConsumer(
            onChunk: { _ in },
            onEnd: {
                .text(
                    "Invalid multipart content type",
                    status: .badRequest
                )
            }
        )
    }
}
```

The helper uses the zero-future throwing synchronous body-stream path internally:

- each incoming chunk is parsed incrementally.
- part bodies are emitted as `ByteBuffer` slices instead of one complete file allocation.
- fragmented boundaries are retained only as a small parser tail.
- `parser.finish()` runs through a throwing synchronous end handler, so malformed closing boundaries enter the normal application error pipeline without creating an end-of-body future.

For lower-level control, `request.multipartParser()` exposes the incremental parser directly.


## Prepared responses

For immutable responses, Hudhud can prebuild the body, content length, and HTTP/1.1 response head during application setup.

```swift
app.get(
    "/health",
    response: .text("ok")
)
```

A prepared route is stored directly in the routing trie. On the normal HTTP/1.1 keep-alive path it avoids:

- Route-handler closure invocation.
- Per-request text-to-`ByteBuffer` conversion.
- Per-request content-length formatting.
- Per-request `HTTPResponseHead` construction.

Prepared headers are also built during setup:

```swift
let health = PreparedResponse
    .text("ok")
    .header("cache-control", "no-store")

app.get("/health", response: health)
```

Prepared cookies and redirects keep the same cached-head path:

```swift
let redirect = PreparedResponse.redirect("/login")

let sessionResponse = PreparedResponse
    .text("ready")
    .cookie(
        "session",
        value: "opaque-token",
        options: CookieOptions(
            path: "/",
            httpOnly: true,
            secure: true,
            sameSite: .lax
        )
    )
```

Use prepared responses only for payloads and headers that are truly immutable.

## File-region responses

Hudhud can send an existing SwiftNIO `FileRegion` without first copying the file into a `ByteBuffer`:

For browser downloads, add a safe `Content-Disposition` header without hand-building header syntax:

```swift
app.get("/download") { _ in
    Response
        .fileRegion(
            region,
            contentType: "application/zip"
        )
        .attachment("archive.zip")
}
```

Unicode filenames emit both a sanitized quoted fallback and RFC 5987 `filename*`. The helper never performs file I/O; callers still own file opening/stat work and the lifetime of the `FileRegion`.

The zero-copy response itself is unchanged:

```swift
app.get("/download") { _ in
    .fileRegion(
        region,
        contentType: "application/octet-stream"
    )
}
```

The response writer emits `IOData.fileRegion` directly and derives `Content-Length` from the readable region. `HEAD` responses preserve the length while suppressing the file body.

Hudhud intentionally does not open filesystem paths synchronously inside this helper. Open files through an appropriate non-blocking/file-service layer, then create the region. The caller owns the underlying file handle and must keep it open until the response write completes.

### SSE writer

`Response.sse` and `writer.writeSSE(...)` provide server-sent events without first building a normalized intermediate response string:

```swift
app.get("/events") { _ in
    Response.sse { writer in
        writer.writeSSE(
            ServerSentEvent(
                data: "ready",
                event: "status",
                id: "1"
            )
        )
    }
}
```

SSE events are serialized directly into a channel-allocator `ByteBuffer`. CRLF and lone CR in event data are normalized to SSE data lines in one UTF-8 pass.

## Error handling

Register one global application error handler for failed NIO futures, thrown async/await routes, and streaming consumer failures:

```swift
app.onError { error, _ in
    Response.text(
        "Request failed",
        status: .internalServerError
    )
}
```

NIO-future handlers are also supported:

```swift
let handler: ErrorHandler = { error, context in
    context.eventLoop.makeSucceededFuture(
        .json(
            #"{"error":"internal"}"#,
            status: .internalServerError
        )
    )
}

app.onError(handler)
```

And Swift concurrency is opt-in:

```swift
app.onError { error, context async throws in
    try await report(error)

    return .text(
        "Request failed",
        status: .internalServerError
    )
}
```

Error handling is not inserted into the successful request pipeline. Prepared, synchronous, and successful asynchronous routes do not perform an error-handler lookup. If a custom future/async error handler itself fails, Hudhud writes the built-in `500 Internal Server Error` directly and does not recursively invoke the custom handler.

Only one global handler is active; the most recent `onError` registration replaces the previous one. Error handlers receive the error and event-loop `Context`, not mutable request state.

## Streaming responses

For generated output that should not be buffered into one large body, return a response stream:

```swift
app.get("/events") { _ in
    Response.stream(
        contentType: "text/event-stream"
    ) { writer in
        writer.writeStringAndFlush(
            "data: ready\n\n"
        )
    }
}
```

The producer returns an `EventLoopFuture<Void>`. Hudhud writes the final HTTP `end` part automatically after that future succeeds.

Multiple chunks can be chained without flushing each chunk:

```swift
app.get("/stream") { _ in
    Response.stream(
        contentType: "text/plain"
    ) { writer in
        writer.writeString("hello").flatMap {
            writer.writeString(" world")
        }
    }
}
```

`ResponseStreamWriter` exposes:

- `write(_:)` and `writeString(_:)` for buffered in-memory writes.
- `writeFileRegion(_:)` for direct file-region body parts.
- `writeAndFlush(_:)`, `writeStringAndFlush(_:)`, and `writeFileRegionAndFlush(_:)` for latency-sensitive output.
- `flush()` to flush previously queued chunks.
- `eventLoop` for scheduling NIO-native asynchronous work.
- `closeFuture` to observe client disconnects.

Stream writes must be serialized on the writer's event loop. If a stream producer fails after response headers have started, Hudhud closes the connection rather than attempting to send a second HTTP response. Use the optional `onError` closure on `Response.stream` or `Response.sse` to clean up producer-owned resources before the connection is closed.

For HTTP/1.1 responses without a declared `Content-Length`, SwiftNIO's response encoder owns chunked transfer framing. For HTTP/1.0, Hudhud closes the connection after an unknown-length stream unless the response explicitly provides a content length.

HEAD requests suppress the stream producer entirely.

### Server-Sent Events

SSE is a small convenience layer over response streaming:

```swift
app.get("/events") { _ in
    Response.sse { writer in
        writer.writeSSE(
            ServerSentEvent(
                data: "build complete",
                event: "status",
                id: "42"
            )
        )
    }
}
```

`writeSSE` flushes each event by default for low delivery latency. Pass `flush: false` when several events should be batched before an explicit `writer.flush()`.

## Connection metadata

Handlers that already receive `Context` can read the raw peer socket address:

```swift
app.get("/peer") { _, context in
    let peer =
        context.remoteAddress?.description
        ?? "unknown"

    return context.eventLoop
        .makeSucceededFuture(
            .text(peer)
        )
}
```

`remoteAddress` is the transport peer reported by SwiftNIO. Hudhud does not automatically trust or parse `X-Forwarded-For` or similar proxy headers. Applications behind a trusted reverse proxy should apply their own explicit proxy-trust policy.

Prepared and ordinary synchronous routes do not construct `Context`, so this metadata does not add address lookup work to those fast paths.

## Middleware

The regular middleware API supports asynchronous NIO work:

```swift
app.use { request, _, next in
    next(request).map { response in
        var response = response
        response.headers.add(
            name: "x-powered-by",
            value: "Hudhud"
        )
        return response
    }
}
```

For middleware that does not require asynchronous I/O, `useFast` preserves Hudhud's synchronous and prepared responder paths:

```swift
app.useFast { request, _, next in
    next(request)
}
```

A pass-through `useFast` middleware does not force an `EventLoopFuture` allocation.

## Current core

- SwiftNIO-based HTTP/1.1 transport.
- Express-style route registration and zero-overhead route groups.
- Direct method roots for common HTTP methods.
- Exact full-path static route table before trie fallback.
- UTF-8 trie routing.
- Route precedence: static segment, dynamic `:param`, then terminal `*catchAll`.
- Routing directly over the URI UTF-8 view with a contiguous-byte fast path.
- Parameter-only trie nodes skip unused static hashing.
- Terminal static/parameter routes avoid an extra recursive matcher call.
- Lazy route parameter decoding from byte ranges.
- Contiguous-byte fast paths for route parameter and targeted query decoding.
- Inline parameter name/range storage for the first two dynamic parameters.
- Lazy query scanning and percent decoding.
- Lazy conversion from SwiftNIO HTTP methods to Hudhud's public method enum.
- Synchronous responder fast path.
- Prepared immutable response fast path.
- Immutable shared prepared-response storage carried directly through the internal pipeline.
- Precomputed HTTP/1.1 heads and body buffers for prepared responses.
- NIO future handlers for asynchronous I/O.
- Global sync, NIO-future, or async/await error handling on failure paths only.
- Compiled asynchronous middleware pipeline.
- Synchronous `useFast` middleware pipeline.
- Opt-in async/await route handlers through SwiftNIO's Task bridge.
- Direct `ByteBuffer` response support.
- Direct `FileRegion` response support through NIO `IOData.fileRegion`.
- Opt-in streaming responses with framework-owned HTTP termination.
- Direct SwiftNIO `FileRegion` response support without ByteBuffer copying.
- Bodyless-request empty-buffer reuse.
- First request-body chunk reuse instead of unconditional copying.
- Opt-in request-body streaming with per-route limits and async backpressure.
- Streaming multipart/form-data parsing with bounded part/header limits.
- Streaming middleware compatibility without whole-body aggregation.
- Configurable request-body limits.
- Opt-in streaming request bodies with per-route limits and backpressure.
- Early rejection of declared oversized streaming bodies before consumer creation.
- HTTP keep-alive and pipelining assistance.
- `Expect: 100-continue` handling with early 413/417 rejection.
- Express-style `HEAD` fallback to matching `GET` routes.
- Correct `HEAD` body suppression while preserving `Content-Length`.
- Configurable event-loop thread count and listen backlog.
- Release benchmark server.
- Raw SwiftNIO control benchmark server.
- Reproducible `wrk` comparison harness.
- Raw SwiftNIO and pinned Actix Web controls.
- Multi-sample benchmark summaries and Linux perf profiling.
- Paired aggregated-vs-streaming upload benchmark.

## Request lifecycle

```text
Socket
  |
  v
SwiftNIO EventLoop
  |
  v
HTTP/1 Decoder
  |
  v
Direct HTTP-method root
  |
  +-- exact static route ----------> endpoint
  |
  v
UTF-8 route trie fallback
  |
  +-- prepared/no middleware -----> cached storage
  |
  v
Request wrapping when required
  |
  v
Compiled middleware / handler
  |
  +-- prepared response -----------+
  |                                |
  +-- synchronous handler -----+   |
  |                            |   |
  +-- future handler ------+   |   |
                          |   |   |
                          v   v   v
                      response writer
                          |
                          v
                        Socket
```

## Performance rules

Hudhud follows several runtime rules:

- Do not create a Swift concurrency `Task` on the default request path.
- Do not split request paths into arrays of Swift `String` values.
- Do not eagerly decode route parameters.
- Do not eagerly parse query parameters.
- Keep synchronous work synchronous.
- Keep reusable response bytes reusable.
- Prefer setup-time work over per-request work.
- Keep the event loop non-blocking.
- Treat allocation count, ARC traffic, CPU, memory, and tail latency as first-class metrics.
- Never publish a speed claim without a reproducible benchmark configuration.

## Why SwiftNIO

SwiftNIO provides the event-loop and non-blocking I/O foundation while Hudhud keeps control over routing, middleware dispatch, request representation, response serialization, allocation behavior, and public API design.

The goal is not to build a large abstraction stack on top of NIO. The goal is to keep the distance between socket and handler small enough to profile and optimize.

## Run

```bash
swift run -c release hudhud-example
```

The example listens on `127.0.0.1:3000`.

## Test

```bash
swift test -c release
```

## Benchmark

Run Hudhud:

```bash
./Benchmarks/run.sh
```

Compare the prepared-response path with a minimal raw SwiftNIO control server:

```bash
./Benchmarks/compare.sh
```

Measure pass-through fast middleware layers:

```bash
FAST_MIDDLEWARE_LAYERS=4 ./Benchmarks/run.sh
```

Run in-process dispatch and writer diagnostics:

```bash
./Benchmarks/core.sh
./Benchmarks/writer-core.sh
```

Compare aggregated and streaming request bodies:

```bash
./Benchmarks/upload.sh
```

Measure incremental multipart parsing against a raw streaming control using identical multipart wire bytes:

```bash
./Benchmarks/multipart.sh
```

Compare peak RSS with the same multipart payload:

```bash
./Benchmarks/multipart-memory.sh
```

Validate benchmark tooling without starting a server:

```bash
./Benchmarks/check.sh
```

See [BENCHMARKS.md](BENCHMARKS.md) for the benchmark protocol and [ARCHITECTURE.md](ARCHITECTURE.md) for runtime invariants.

## Next performance targets

1. Run the repeated Hudhud-to-raw-NIO suite on pinned hardware and record median/p99 deltas.
2. Run the core dispatch and writer benchmarks before changing NIO response-part boxing.
3. Profile ARC retain/release traffic for prepared, synchronous, dynamic-parameter, async/await, and streaming routes.
4. Quantify route depth/fan-out and middleware scaling with the committed matrices.
5. Measure aggregated versus streaming uploads with both throughput and peak-RSS runners.
6. Measure known-length, chunked, and flush-heavy response streams independently.
7. Compare the pinned Actix Web control only after Hudhud's raw-NIO framework overhead is measured and explained.
