# Hudhud

Hudhud is an experimental high-performance web framework written entirely in Swift.

The project has two non-negotiable goals:

1. An ergonomic developer experience inspired by Express.js.
2. A low-overhead runtime architecture designed to push Swift server performance as far as practical.

Hudhud is currently pre-alpha. The API and internals can change aggressively while the runtime architecture is being established.

## Requirements

- Swift 6.4 is the development and benchmark toolchain.
- Swift Package Manager tools version 6.1 or newer.
- SwiftNIO 2.104.0, pinned exactly for reproducible builds.

## Example

```swift
import Hudhud

let app = Application()

app.use { request, context, next in
    next(request).map { response in
        var response = response
        response.headers.replaceOrAdd(
            name: "x-powered-by",
            value: "Hudhud"
        )
        return response
    }
}

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

## Current core

- SwiftNIO-based HTTP/1.1 transport.
- Express-style route registration.
- Method-aware UTF-8 trie router.
- Static route priority with dynamic-parameter fallback.
- Lazy route parameter decoding from URI byte ranges.
- Lazy query parsing and percent decoding.
- Synchronous responder fast path that avoids creating an `EventLoopFuture` for ordinary synchronous routes.
- NIO future handlers for asynchronous I/O.
- Compiled middleware pipeline.
- Direct `ByteBuffer` response support.
- HTTP keep-alive and pipelining assistance.
- Express-style `HEAD` fallback to matching `GET` routes.
- Correct `HEAD` body suppression while preserving `Content-Length`.
- Configurable request-body limits.
- Configurable event-loop thread count and listen backlog.
- Release benchmark server and `wrk` harness.
- Unit tests for routing, middleware, request parsing, fast-path dispatch, HTTP semantics, and request-body limits.

## Performance design

Hudhud deliberately keeps the default synchronous request path separate from asynchronous I/O.

```text
Socket
  |
  v
SwiftNIO EventLoop
  |
  v
HTTP Decoder
  |
  v
URI UTF-8 View
  |
  v
Compiled Middleware Chain
  |
  v
Method-aware Trie Router
  |
  +-- static edge
  |
  +-- parameter edge -> byte range
  |
  v
Immediate Response or Future
  |
  v
ByteBuffer
  |
  v
Socket
```

Important rules:

- No Swift concurrency `Task` is created on the default request hot path.
- Static routing does not split the URI into an array of Swift `String` values.
- Route parameter strings are decoded only when the application reads them.
- Query parameters are scanned only when the application asks for them.
- Synchronous handlers return through an immediate internal responder path.
- Performance claims must come from reproducible release-build measurements.

## Why SwiftNIO

SwiftNIO provides the event-loop and non-blocking I/O foundation while Hudhud keeps control over routing, middleware dispatch, request representation, response serialization, allocation behavior, and public API design.

The goal is not to recreate a large framework on top of NIO. The goal is to keep the distance between the socket and the application handler small and measurable.

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

```bash
./Benchmarks/run.sh
```

See [BENCHMARKS.md](BENCHMARKS.md) for the comparison protocol and current optimization targets.

## Next performance targets

1. Reduce response-header and response-body allocations for static responses.
2. Add a prepared response path for reusable immutable payloads.
3. Measure the framework overhead against a minimal raw SwiftNIO server.
4. Quantify middleware overhead per layer.
5. Profile ARC retain/release traffic.
6. Measure route matching by route count and depth.
7. Evaluate a synchronous middleware fast path.
8. Add structured comparisons against Hummingbird, Vapor, and Actix Web only after the raw-NIO delta is understood.
