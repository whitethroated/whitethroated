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

Use prepared responses only for payloads that are truly immutable.

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
- UTF-8 trie routing.
- Static route priority with dynamic-parameter fallback.
- Routing directly over the URI UTF-8 view.
- Lazy route parameter decoding from byte ranges.
- Inline parameter-range storage for the first two dynamic parameters.
- Lazy query scanning and percent decoding.
- Synchronous responder fast path.
- Prepared immutable response fast path.
- Precomputed HTTP/1.1 heads for prepared responses.
- NIO future handlers for asynchronous I/O.
- Compiled asynchronous middleware pipeline.
- Synchronous `useFast` middleware pipeline.
- Direct `ByteBuffer` response support.
- Bodyless-request empty-buffer reuse.
- First request-body chunk reuse instead of unconditional copying.
- Configurable request-body limits.
- HTTP keep-alive and pipelining assistance.
- Express-style `HEAD` fallback to matching `GET` routes.
- Correct `HEAD` body suppression while preserving `Content-Length`.
- Configurable event-loop thread count and listen backlog.
- Release benchmark server.
- Raw SwiftNIO control benchmark server.
- Reproducible `wrk` comparison harness.

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
Request wrapping
  |
  v
Compiled middleware
  |
  v
Direct HTTP-method root
  |
  v
UTF-8 route trie
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

Measure a pass-through fast middleware layer:

```bash
FAST_MIDDLEWARE=1 ./Benchmarks/run.sh
```

See [BENCHMARKS.md](BENCHMARKS.md) for the benchmark protocol and [ARCHITECTURE.md](ARCHITECTURE.md) for runtime invariants.

## Next performance targets

1. Measure the Hudhud-to-raw-NIO delta on pinned hardware.
2. Combine route scanning and segment hashing into fewer byte passes.
3. Measure route depth and route-count scaling.
4. Profile ARC retain/release traffic.
5. Quantify `useFast` and asynchronous middleware overhead per layer.
6. Investigate response encoder/write batching only from profiler evidence.
7. Add Actix Web comparison after Hudhud's raw-NIO overhead is understood.
