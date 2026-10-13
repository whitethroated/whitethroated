# Hudhud

Hudhud is an experimental high-performance web framework written entirely in Swift.

The project has two non-negotiable goals:

1. An ergonomic developer experience inspired by Express.js.
2. A low-overhead runtime architecture designed to push Swift server performance as far as practical.

Hudhud is currently pre-alpha.

## Example

```swift
import Hudhud

let app = Application()

app.use { request, context, next in
    next(request).map { response in
        var response = response
        response.headers.replaceOrAdd(name: "x-powered-by", value: "Hudhud")
        return response
    }
}

app.get("/") { _ in
    .text("Hello from Hudhud")
}

app.get("/users/:id") { request in
    let id = request.parameter("id") ?? "unknown"
    return .json(#"{"id":"\#(id)"}"#)
}

try app.run(port: 3000)
```

## Current core

- Swift Package Manager package.
- SwiftNIO-based HTTP/1.1 server.
- Express-style route registration.
- Static and parameterized routes.
- GET, POST, PUT, PATCH, and DELETE helpers.
- Request headers and body access.
- Text, JSON, byte, empty, 404, and 500 responses.
- Middleware pipeline.
- Keep-alive support.
- Unit-testable request dispatch.
- Release benchmark guide.

## Design principles

- Swift-first public API.
- SwiftNIO event loops as the transport foundation.
- No Swift concurrency `Task` creation on the default request hot path.
- Minimal abstraction between the socket and the route handler.
- Prefer allocation-aware data structures in hot paths.
- Route registration happens during application setup.
- Synchronous handlers get a direct fast path.
- NIO futures remain available for asynchronous I/O without leaving the event loop model.
- Performance claims must come from reproducible release-build benchmarks.

## Why NIO first

Hudhud is not trying to beat Actix by adding more abstractions on top of an already expensive request path.

SwiftNIO provides the event-loop and non-blocking I/O primitives needed to build a serious Swift server runtime while still giving Hudhud control over routing, middleware dispatch, response serialization, allocation behavior, and API design.

That gives us a measurable optimization surface.

## Performance roadmap

The current router intentionally starts simple. It is not the final high-performance router.

The next performance milestones are:

1. Replace linear route scanning with a method-aware radix tree.
2. Match paths without allocating an array of Swift `String` values per request.
3. Introduce direct `ByteBuffer` response bodies.
4. Reduce dictionary allocation for route parameters.
5. Benchmark middleware dispatch overhead independently.
6. Profile ARC retains/releases in the request hot path.
7. Add parser/body-size limits and production-safe error handling.
8. Add structured benchmark runs against raw SwiftNIO, Hummingbird, Vapor, and Actix Web.
9. Optimize from latency, throughput, CPU, memory, and tail latency together.
10. Add HTTP/2 only after the HTTP/1.1 execution path is well understood.

See [BENCHMARKS.md](BENCHMARKS.md).

## Run

```bash
swift run -c release hudhud-example
```

The example listens on `127.0.0.1:3000`.

## Test

```bash
swift test
```

## Status

Pre-alpha. The API can change aggressively while the runtime architecture is being established.
