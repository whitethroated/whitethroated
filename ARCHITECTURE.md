# Hudhud architecture

This document defines the runtime invariants for Hudhud.

The framework is pre-alpha, so implementation details may change. These invariants should change only when benchmark or correctness evidence justifies it.

## Goals

Hudhud aims to provide:

- Swift-native server APIs with an Express.js-like level of ergonomics.
- Predictable non-blocking execution.
- A very small synchronous request hot path.
- Low allocation pressure.
- Explicit escape hatches to SwiftNIO primitives.
- Reproducible performance measurement.

The performance target is not a specific requests-per-second number. The target is to minimize framework overhead until Swift runtime, SwiftNIO, kernel, and hardware costs dominate.

## Non-goals

Hudhud does not currently optimize for:

- Source compatibility during pre-alpha.
- A large batteries-included ecosystem.
- Hiding SwiftNIO completely.
- Blocking APIs on event-loop threads.
- Performance claims based on synthetic throughput alone.

## Setup phase and serving phase

Application configuration happens before `listen` or `run`.

Setup work includes:

- Route registration.
- Route-group prefix composition.
- Prepared-response construction.
- Middleware registration.
- Server configuration.

When the server starts, configuration is frozen. Route and middleware mutation after serving begins is rejected.

Router data structures are therefore setup-mutable and serving-read-only.

## Event-loop model

Hudhud uses SwiftNIO event loops as its primary concurrency model.

Rules:

1. Never block an event-loop thread.
2. Do not create a Swift `Task` per request on the default path.
3. Use NIO futures for event-loop-native asynchronous I/O.
4. Offload genuinely blocking work to an appropriate external executor.
5. Keep request-local operations on the current event loop when possible.

## Transport dispatch

The transport path intentionally distinguishes endpoints before constructing higher-level request objects.

With no middleware installed:

```text
HTTP request head
  |
  v
NIO HTTP method + URI UTF-8 view
  |
  v
Router lookup
  |
  +-- prepared endpoint ----------> prepared writer
  |
  +-- synchronous endpoint ------> build Request -> sync handler
  |
  +-- NIO-future endpoint -------> build Request + Context -> future handler
  |
  +-- async/await endpoint -------> build Request -> Task -> future bridge
  |
  +-- not found -----------------> immediate 404
```

A prepared endpoint therefore does not require:

- `Request` construction.
- `Context` construction.
- Conversion from `NIOHTTP1.HTTPMethod` to Hudhud's public `HTTPMethod`.
- Handler closure invocation.

When middleware exists, Hudhud constructs `Request` before the middleware pipeline because middleware is allowed to inspect or transform the request.

`Request` stores the original SwiftNIO HTTP method and converts it to Hudhud's public `HTTPMethod` only when application code reads `request.method`. Internal routing uses the original NIO method even when middleware is installed, so middleware does not accidentally force public-method conversion merely to resolve an endpoint. On the middleware-free transport path, matched route parameter metadata is installed during request initialization rather than through follow-up mutation.

## Responder paths

Hudhud has three internal response paths.

### Prepared

A `PreparedResponse` is immutable setup-time work.

For HTTP/1.1 keep-alive requests it can reuse:

- Prebuilt body bytes.
- Precomputed content length.
- Precomputed response head.

Prepared routes are stored directly in route endpoints.

A `PreparedResponse` is a small value wrapper around immutable shared storage containing the fallback response, cached HTTP/1.1 head, and cached body buffer. Route endpoints, internal router matches, and responder results carry that storage reference directly. Public middleware wraps it back into `PreparedResponse` only when the middleware API requires the public type.

### Immediate

A synchronous route returns a `Response` without creating an `EventLoopFuture`.

Synchronous handlers are stored separately from asynchronous handlers in the trie, so they do not pass through an async wrapper.

### Future

Handlers performing asynchronous NIO work return an `EventLoopFuture<Response>`.

`Context` and future allocation are paid only by paths that require them.

### Async/await

An `AsyncHandler` is an opt-in Swift concurrency path. Hudhud bridges it through SwiftNIO's `EventLoopPromise.completeWithTask`.

This path intentionally creates a Swift `Task` for that request. It must never become an implicit wrapper around synchronous, prepared, or NIO-future handlers.

## Error paths

Application error handling is a failure-only facility.

A configured error handler may be:

- synchronous, returning `Response`.
- event-loop-native, returning `EventLoopFuture<Response>`.
- Swift async/await, bridged through a task only after a failure occurs.

Successful prepared, synchronous, NIO-future, and async/await responses do not query or wrap through the error handler.

Future failures from routes and middleware, async/await throws, streaming chunk failures, and failed streaming completion futures are converted through the global error handler. If the custom error handler fails, the transport writes the built-in 500 response directly. It must never recursively invoke the custom handler for an error produced by that same handler.

The error handler receives `Error` plus `Context`. It intentionally does not depend on mutable transport request state, because asynchronous failures may complete after the handler has reset per-request channel state for pipelining.

## Middleware paths

`use` is the asynchronous middleware API and intentionally returns NIO futures.

`useFast` is the low-overhead middleware API. It carries a `MiddlewareResult` that can remain:

- Prepared.
- Immediate.
- Future.

A pass-through fast middleware must not promote a prepared or immediate downstream response into a future.

A fast middleware that transforms a prepared response into a mutable `Response` intentionally gives up the precomputed prepared-response writer path.

## Routing

Canonical static routes are registered in two setup-time structures:

1. An exact full-path table keyed by FNV-1a hash.
2. The segment trie used by dynamic parameters, catch-all routes, and semantic fallbacks.

For a canonical static URI, Hudhud hashes the path bytes once up to the query marker and performs one exact-table lookup. No `String` is created and route parameters are not involved.

If exact lookup misses, routing falls back to the existing UTF-8 trie. This preserves trailing-slash behavior and mixed static/dynamic route precedence.

`HEAD` lookup order is intentionally:

1. Exact `HEAD` route.
2. `HEAD` trie route.
3. Exact `GET` fallback.
4. `GET` trie fallback.

This prevents an exact `GET` route from incorrectly outranking a dynamic route explicitly registered for `HEAD`.

Static endpoints are duplicated as lightweight setup-time metadata between the exact table and trie. The tradeoff is additional route-table memory in exchange for fewer serving-time lookups on canonical static routes.


The router is method-aware.

Common NIO HTTP methods dispatch directly to dedicated roots. Custom or uncommon methods use the Hudhud method mapping and fallback root dictionary.

Path matching operates directly on URI UTF-8 bytes.

Current trie behavior:

- Static segment first.
- Single-segment `:param` second.
- Terminal `*catchAll` third.
- Static branches can backtrack into parameter or catch-all branches when needed.
- Query-string bytes terminate route matching.
- Contiguous URI UTF-8 storage is matched through `UnsafeBufferPointer<UInt8>` with integer indices.
- Non-contiguous URI storage falls back to the zero-copy `String.UTF8View` matcher.
- Segment boundary scanning and FNV-1a hashing happen in the same byte pass when a node actually has static children.
- Parameter-only nodes skip static hashing entirely.
- Terminal static/parameter matches avoid an extra recursive trie call.
- Catch-all-only nodes scan the remaining URI once, stopping at the query string.
- Static hash buckets store one edge directly and allocate collision arrays only if a 64-bit hash collision occurs.
- The first two dynamic parameter names and ranges are stored inline.
- A third parameter promotes name/range storage to arrays.
- Parameter strings are decoded only when application code reads them.
- Parameter decoding reuses contiguous URI byte storage and integer ranges when available.
- `HEAD` uses an explicit HEAD route first and falls back to GET.

Catch-all parameters must be the final route segment.

Static and dynamic routes do not normalize repeated slashes. A path such as `/admin//users` does not match `/admin/users`. Terminal catch-all parameters preserve repeated slashes inside the captured remainder because wildcard matching is explicit.

Route registration rejects patterns containing repeated slashes.

Do not introduce eager request-path splitting into `[String]`.

## Route groups

Route groups are a registration-time abstraction.

```text
group("/api") + group("/v1") + get("/users")
                         |
                         v
                 /api/v1/users
                         |
                         v
                 normal router insert
```

No group object or prefix matching exists in the request hot path.

The same rule applies to `all(...)`: it expands into concrete method routes during application setup.

## Query parsing

Queries are not parsed during request construction.

`request.query(name)` scans lazily and stops after the requested key is found. When URI UTF-8 storage is contiguous, targeted lookup uses integer-indexed bytes directly.

`request.queryParameters` materializes a dictionary only when requested.

Percent decoding is implemented without Foundation URL parsing in the route/query hot path.

## URL-encoded forms

URL-encoded form parsing is opt-in and operates directly on the aggregated request `ByteBuffer` view.

- `request.form(name)` performs a targeted scan and stops on the first decoded matching key.
- `request.formParameters` allocates a dictionary only when the full form is requested.
- Percent decoding reuses the same byte-oriented decoder as query parsing.
- Requests that do not access form APIs pay no parsing cost.

## JSON

Codable JSON support is opt-in.

- `request.decodeJSON` copies body bytes into `Data` only when called.
- `Response.json(Encodable)` encodes only when called.
- `PreparedResponse.json(Encodable)` performs encoding during setup and then uses the prepared response path.

JSON convenience must never add encoding or Foundation parsing to requests that do not use it.

## Request bodies

Bodyless ordinary requests reuse an empty buffer owned by the channel handler.

For ordinary routes, the first received request-body chunk is reused directly. Additional chunks are appended only when necessary.

Request-body limits are enforced while chunks arrive.

Streaming routes are detected from the request head only when the application registered at least one streaming endpoint. Applications with no streaming routes retain the ordinary one-lookup transport path.

A streaming route receives a `StreamRequest` plus a `BodyStreamConsumer`. The request metadata is available before the first body chunk, but no aggregated body is exposed.

Streaming invariants:

- Non-throwing synchronous chunk consumption invokes the user closure directly and allocates no future.
- Throwing synchronous chunk consumption also allocates no future on success; thrown errors enter the streaming failure path directly.
- Async chunk consumption returns `EventLoopFuture<Void>`.
- Async chunk futures are hopped to the channel event loop before transport state is mutated.
- Channel auto-read is paused while an async chunk is pending.
- Already-decoded chunks may be queued temporarily in a SwiftNIO `CircularBuffer`, so dequeue remains O(1), while new socket reads remain paused until the consumer catches up.
- Per-route body limits can override the global body limit.
- Middleware may short-circuit a streaming route; the transport then drains/discards the body without invoking the consumer.
- Async middleware may delay route resolution; auto-read is paused until the middleware either reaches the stream route or short-circuits it.
- Client disconnects and channel errors fail the active streaming session.
- Ordinary routes never become streaming implicitly.
- Streaming-route detection is tracked per HTTP method so unrelated methods avoid an extra route lookup.
- On a middleware-free method that mixes streaming and ordinary routes, the head-time route match is cached and reused after ordinary body aggregation. The request therefore does not traverse the trie twice.

For `Expect: 100-continue`:

- Valid HTTP/1.1 expectations receive an informational 100 head before body processing.
- A declared body that already exceeds its limit receives a final 413 response and connection close immediately.
- Unsupported expectations receive 417 and connection close.
- Early rejection never waits for a request-body end marker that the client may intentionally withhold.

Streaming therefore avoids whole-body aggregation while preserving middleware semantics and backpressure.

## Multipart request bodies

Multipart parsing is an opt-in layer over request-body streaming. It does not change the ordinary aggregated request path or router hot path.

`BodyStreamConsumer.multipart(...)` composes the incremental parser with the throwing synchronous chunk and end responders. Valid multipart chunks therefore create no per-chunk future, while parser errors still propagate through the existing streaming/application error pipeline.

Runtime invariants:

- The complete multipart request body is never intentionally accumulated.
- Part headers are buffered only until `\r\n\r\n` and are capped by `maxHeaderBytesPerPart`.
- Part headers are scanned directly from `ByteBufferView`; Hudhud does not construct a full header-block `String` or split it into an intermediate line array.
- Obsolete folded headers and unsafe control bytes in header values are rejected.
- Part count and header count are independently bounded.
- An optional `maxPartBodyBytes` limit is checked incrementally before each part-body chunk is emitted; bytes that would cross the limit are not delivered to the application sink.
- While scanning part bodies, the parser emits completed body bytes incrementally and retains only the longest trailing byte sequence that is an actual prefix of the multipart boundary.
- For ordinary payload chunks that do not end in a possible boundary prefix, no body tail is retained; the next inbound `ByteBuffer` can become parser input directly instead of being appended behind a fixed boundary-sized tail.
- Boundary matching validates the complete delimiter line. Boundary-like byte sequences such as `\r\n--boundary--X` inside file content are preserved instead of being treated as closing delimiters.
- RFC 2046 transport padding (space/tab) is accepted on delimiter lines but bounded by `maxBoundaryPaddingBytes` to prevent unbounded staging from malicious whitespace.
- A closing delimiter may terminate exactly at the request-body end or be followed by CRLF and an ignored epilogue.
- The parser accepts binary part bodies and does not decode part payload bytes as text.
- `Content-Disposition: form-data; name=...` is required for every part.
- Parser state is expected to remain confined to the request event-loop flow. The parser is marked `@unchecked Sendable` only so it can be captured by Hudhud's `@Sendable` streaming closures without introducing locking on every chunk.
- Multipart parsing should normally use the throwing-synchronous chunk responder so successful parsing does not allocate an `EventLoopFuture` per inbound chunk.
- Client-provided filenames are metadata only and must not be trusted as filesystem paths.

The parser's internal staging buffer can grow to the size of an inbound chunk plus multipart framing state, but it is not a whole-upload accumulator.

## Byte ranges

Byte-range parsing is opt-in and header-only.

- `request.byteRange(totalLength:)` parses one `bytes` range only when application code asks for it.
- Parsing is byte-oriented and does not split the header into intermediate strings.
- Closed, open-ended, and suffix ranges are supported.
- Multiple ranges are surfaced as `.unsupportedMultiple`; Hudhud does not implicitly allocate a multipart/byteranges response.
- `Response.partialFileRegion` constructs a sliced `FileRegion`, preserving zero-copy transport behavior.
- 206 and 416 helpers set the required `Content-Range` and `Accept-Ranges` metadata without filesystem I/O.

## Responses

Ordinary text and byte responses may allocate or serialize per request.

Streaming responses use chunked HTTP/1.1 framing when no `Content-Length` is supplied. When application code explicitly supplies `Content-Length`, Hudhud enables byte accounting for that stream only:

- Writes that would exceed the declared length fail before the overflow bytes are written.
- Producer completion with fewer bytes than declared is treated as a framing error.
- Invalid, negative, duplicate, or comma-combined declared lengths fail before the streaming response head is emitted.
- A length mismatch after response streaming begins closes the connection instead of emitting a misleading HTTP end marker.

Unknown-length streams do not allocate or update a length tracker.

`ResponseStreamWriter.write(...)` is a buffered enqueue operation. It writes into the NIO pipeline without installing a per-write completion promise and returns the event loop's cached succeeded `Void` future. This lets producers compose buffered writes with `flatMap` without waiting for a flush that only occurs when the producer completes. `writeAndFlush(...)` remains the explicit API for callers that need a future tied to a flushed transport write.

A `Response.fileRegion` body is written as `IOData.fileRegion` directly. Hudhud derives content length from the region and does not copy file bytes into a `ByteBuffer`. The caller retains ownership of the underlying file handle and must keep it valid until the write completes.

Hudhud must not introduce a convenience API that performs blocking file-open or file-stat work on an event-loop thread.

Use `PreparedResponse` for immutable in-memory payloads where avoiding repeated serialization matters.

Streaming responses are opt-in. Hudhud writes the response head, lets the producer emit HTTP body parts on the channel event loop, and writes the terminal HTTP end after the producer future succeeds. SwiftNIO's HTTP response encoder remains responsible for wire framing such as HTTP/1.1 chunked transfer encoding.

If a streaming producer fails after headers have started, Hudhud invokes the optional response-stream error cleanup hook and closes the connection rather than attempting to emit a second response. Client disconnects can be observed through the stream writer's close future. HEAD requests suppress the producer. HTTP/1.0 unknown-length streams force connection-close framing unless an explicit content length is supplied.

SSE is implemented as a formatting/header convenience over the same response-stream path. It does not introduce a separate transport abstraction.

A response writer must preserve:

- Correct `Content-Length`.
- HEAD semantics.
- HTTP version semantics.
- Keep-alive semantics.
- Response ordering under HTTP pipelining.

Correctness wins over a microbenchmark.

## Memory and ARC

Performance work should inspect:

- Heap allocations per request.
- ARC retain/release count.
- Copy-on-write mutations.
- String decoding.
- Header materialization.
- ByteBuffer copying.
- Closure and future allocation.

Do not assume an abstraction is expensive. Measure it.

## Profiling discipline

Before adding a hot-path optimization, prefer evidence from:

- repeated `wrk` samples.
- Linux `perf stat` counters.
- sampled call stacks from `perf record`.
- visible Swift ARC symbols such as retain/release functions.
- allocation tooling when available on the target platform.

A code change that makes source code more complex without moving a measured bottleneck should not be treated as a performance win.

## Server-sent events

SSE serialization writes directly into a channel-allocator `ByteBuffer`.

- Event/id fields are appended directly without response-string concatenation.
- Data is scanned once as UTF-8.
- LF, CRLF, and lone CR are normalized while bytes are copied into the outbound buffer.
- Multiline data does not allocate an intermediate normalized `String` or line array.
- `writeSSE(..., flush: true)` retains the latency-oriented explicit-flush behavior.

This path is opt-in and has no effect on ordinary responses.

## Benchmark hierarchy

Performance work should proceed in this order:

1. Hudhud versus minimal raw SwiftNIO with identical behavior.
2. Hudhud feature deltas, such as prepared versus normal responses.
3. Router depth, fan-out, and parameter-capture scaling.
4. Middleware scaling.
5. ARC and allocation profiling.
6. Cross-framework Swift comparisons.
7. Actix Web comparison.

If Hudhud is materially slower than the raw-NIO control, investigate Hudhud before blaming Swift.

## Benchmark invariants

Every published result should record:

- Hudhud commit SHA.
- Compiler version.
- SwiftNIO version.
- Hardware.
- Operating system.
- Build mode.
- HTTP protocol.
- Connection count.
- Benchmark duration.
- Benchmark tool and command.
- CPU utilization.
- Memory.
- Tail latency.

A single requests-per-second number is not sufficient evidence.

## Performance review checklist

Before merging a hot-path change, ask:

- Does it add an allocation to every request?
- Does it add a dictionary or String conversion to every request?
- Does it construct `Request` for an endpoint that does not need one?
- Does it force a synchronous path into a future?
- Does error handling add work to successful requests?
- Can an error-handler failure recurse indefinitely?
- Does it introduce a `Task`?
- Does it copy a ByteBuffer unnecessarily?
- Could a file download use `FileRegion` instead of reading the file into memory?
- Does an upload path aggregate bytes that could remain streaming?
- Does async body processing apply backpressure instead of building an unbounded queue?
- Does it mutate copy-on-write storage?
- Does it add work for requests that do not use the feature?
- Can the work happen during application setup instead?
- Is there a benchmark that isolates the claimed improvement?
- Are HTTP semantics still correct?
