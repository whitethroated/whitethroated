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
  +-- asynchronous endpoint -----> build Request + Context -> future handler
  |
  +-- not found -----------------> immediate 404
```

A prepared endpoint therefore does not require:

- `Request` construction.
- `Context` construction.
- Conversion from `NIOHTTP1.HTTPMethod` to Hudhud's public `HTTPMethod`.
- Handler closure invocation.

When middleware exists, Hudhud constructs `Request` before the middleware pipeline because middleware is allowed to inspect or transform the request.

## Responder paths

Hudhud has three internal response paths.

### Prepared

A `PreparedResponse` is immutable setup-time work.

For HTTP/1.1 keep-alive requests it can reuse:

- Prebuilt body bytes.
- Precomputed content length.
- Precomputed response head.

Prepared routes are stored directly in route endpoints.

### Immediate

A synchronous route returns a `Response` without creating an `EventLoopFuture`.

Synchronous handlers are stored separately from asynchronous handlers in the trie, so they do not pass through an async wrapper.

### Future

Handlers performing asynchronous NIO work return an `EventLoopFuture<Response>`.

`Context` and future allocation are paid only by paths that require them.

## Middleware paths

`use` is the asynchronous middleware API and intentionally returns NIO futures.

`useFast` is the low-overhead middleware API. It carries a `MiddlewareResult` that can remain:

- Prepared.
- Immediate.
- Future.

A pass-through fast middleware must not promote a prepared or immediate downstream response into a future.

A fast middleware that transforms a prepared response into a mutable `Response` intentionally gives up the precomputed prepared-response writer path.

## Routing

The router is method-aware.

Common NIO HTTP methods dispatch directly to dedicated roots. Custom or uncommon methods use the Hudhud method mapping and fallback root dictionary.

Path matching operates directly on URI UTF-8 bytes.

Current trie behavior:

- Static segment first.
- Single-segment `:param` second.
- Terminal `*catchAll` third.
- Static branches can backtrack into parameter or catch-all branches when needed.
- Query-string bytes terminate route matching.
- Segment boundary scanning and FNV-1a hashing happen in the same byte pass.
- Static hash buckets store one edge directly and allocate collision arrays only if a 64-bit hash collision occurs.
- The first two dynamic parameter ranges are stored inline.
- A third parameter promotes range storage to an array.
- Parameter strings are decoded only when application code reads them.
- `HEAD` uses an explicit HEAD route first and falls back to GET.

Catch-all parameters must be the final route segment.

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

`request.query(name)` scans lazily and stops after the requested key is found.

`request.queryParameters` materializes a dictionary only when requested.

Percent decoding is implemented without Foundation URL parsing in the route/query hot path.

## JSON

Codable JSON support is opt-in.

- `request.decodeJSON` copies body bytes into `Data` only when called.
- `Response.json(Encodable)` encodes only when called.
- `PreparedResponse.json(Encodable)` performs encoding during setup and then uses the prepared response path.

JSON convenience must never add encoding or Foundation parsing to requests that do not use it.

## Request bodies

Bodyless requests reuse an empty buffer owned by the channel handler.

The first received request-body chunk is reused directly. Additional chunks are appended only when necessary.

Request-body limits are enforced while chunks arrive.

Future body-streaming support should avoid forcing all endpoints back into an eager aggregation model.

## Responses

Ordinary text and byte responses may allocate or serialize per request.

Use `PreparedResponse` for immutable payloads where avoiding repeated serialization matters.

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
- Does it introduce a `Task`?
- Does it copy a ByteBuffer unnecessarily?
- Does it mutate copy-on-write storage?
- Does it add work for requests that do not use the feature?
- Can the work happen during application setup instead?
- Is there a benchmark that isolates the claimed improvement?
- Are HTTP semantics still correct?
