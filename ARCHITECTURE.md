# Hudhud architecture

This document defines the runtime invariants for Hudhud.

The framework is pre-alpha, so implementation details may change. The invariants below should change only when benchmark or correctness evidence justifies it.

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

Application configuration is expected to happen before `listen` or `run`.

Setup work includes:

- Route registration.
- Prepared-response construction.
- Middleware registration.
- Server configuration.

Serving work includes:

- Request decoding.
- Middleware dispatch.
- Route matching.
- Application handler execution.
- Response writing.

Do not mutate routes or middleware while the application is serving. Router data structures are designed around setup-time mutation followed by read-only serving.

## Event-loop model

Hudhud uses SwiftNIO event loops as its primary concurrency model.

Rules:

1. Never block an event-loop thread.
2. Do not create a Swift `Task` per request on the default path.
3. Use NIO futures for event-loop-native asynchronous I/O.
4. Offload genuinely blocking work to an appropriate external executor.
5. Keep request-local operations on the current event loop when possible.

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

Use this for CPU-light synchronous request processing.

### Future

Handlers performing asynchronous NIO work return an `EventLoopFuture<Response>`.

Future allocation is paid only when the application actually uses that path or when asynchronous middleware requires it.

## Middleware paths

`use` is the asynchronous middleware API and intentionally returns NIO futures.

`useFast` is the low-overhead middleware API. It carries a `MiddlewareResult` that can remain:

- Prepared.
- Immediate.
- Future.

A pass-through fast middleware must not promote a prepared or immediate downstream response into a future.

A fast middleware that transforms a prepared response into a mutable `Response` intentionally gives up the prepared response-head fast path.

## Routing

The router is method-aware.

Common HTTP methods have direct root references rather than a dictionary lookup. Custom methods use a fallback dictionary.

Path matching operates on the request URI UTF-8 view.

Current trie behavior:

- Static segment first.
- Dynamic parameter fallback.
- Static branches can backtrack into a parameter branch if the static branch dead-ends.
- Query-string bytes terminate route matching.
- Dynamic parameter values are stored as URI byte ranges.
- Parameter strings are decoded only when requested by application code.
- `HEAD` uses an explicit HEAD route first and falls back to GET.

Do not introduce eager path splitting into `[String]` on the request path.

## Query parsing

Queries are not parsed during request construction.

`request.query(name)` scans lazily and stops after the requested key is found.

`request.queryParameters` materializes a dictionary only when requested.

Percent decoding is implemented without Foundation URL parsing in the request hot path.

## Request bodies

Bodyless requests reuse an empty buffer owned by the channel handler.

The first received request-body chunk is reused directly. Additional chunks are appended only when necessary.

Request-body limits are enforced while chunks arrive.

Future body-streaming support should avoid forcing all endpoints back into an eager aggregation model.

## Responses

Ordinary text and byte responses may allocate/serialize per request.

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
3. Middleware and router scaling.
4. Cross-framework Swift comparisons.
5. Actix Web comparison.

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
- Does it force a synchronous path into a future?
- Does it introduce a `Task`?
- Does it copy a ByteBuffer unnecessarily?
- Does it mutate copy-on-write storage?
- Does it add work for requests that do not use the feature?
- Can the work happen during application setup instead?
- Is there a benchmark that isolates the claimed improvement?
- Are HTTP semantics still correct?
