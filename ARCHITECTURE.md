# WhiteThroated architecture

This document defines the runtime invariants for WhiteThroated.

The framework is pre-alpha, so implementation details may change. These invariants should change only when benchmark or correctness evidence justifies it.

## Goals

WhiteThroated aims to provide:

- Swift-native server APIs with an Express.js-like level of ergonomics.
- Predictable non-blocking execution.
- A very small synchronous request hot path.
- Low allocation pressure.
- Explicit escape hatches to SwiftNIO primitives.
- Reproducible performance measurement.

The performance target is not a specific requests-per-second number. The target is to minimize framework overhead until Swift runtime, SwiftNIO, kernel, and hardware costs dominate.

## Non-goals

WhiteThroated does not currently optimize for:

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

## Module boundary

The package has three framework targets with one-way dependencies:

```text
Developer API
     |
     v
WhiteThroated ── framework: Application, Router, middleware,
     |           Request/Response, JSON, cookies, ETags
     v
WhiteThroatedRuntime ── runtime: bootstrap, HTTP/1.1 pipeline,
     |                  dispatch state machine, body mechanics,
     |                  response writer, keep-alive, backpressure
     +── WhiteThroatedHTTP1 ── byte parser and response serializer
     v
SwiftNIO
     |
     v
OS networking (epoll / kqueue)
```

`WhiteThroatedRuntime` is an internal module in this repository, not
a separate framework or package. Normal users import only
`WhiteThroated`. The runtime must not know about route
registration, route groups, middleware composition, or developer
convenience APIs; it exposes the smallest interface the framework
needs: `RuntimeServer`, `RuntimeConnectionHandler`,
`RuntimeResponseWriter`, `RuntimeStreamWriter`, the
`RuntimeRequest`/`RuntimeResponse`/`RuntimePreparedResponse` value
types, and the `RuntimeDispatcher` struct-of-closures bridge.

The dispatcher is a plain struct of `@Sendable` closures built once
per application: route lookup, middleware-pipeline dispatch, error
mapping, and four prebuilt fixed responses (404, 413, 417, 500).
There are no protocols, existentials, or per-request allocations in
the bridge. The runtime invokes every closure on the connection
event loop; futures may complete anywhere and the runtime hops
completion back before writing.

`WhiteThroated` depends on `NIOCore`/`NIOHTTP1` plus
`WhiteThroatedRuntime`, and deliberately not on `NIOPosix`:
event-loop groups and server bootstrap live in the runtime.

`WhiteThroatedHTTP1` imports only `NIOCore`. It has no framework or
dispatcher concepts. The runtime converts parsed heads to NIOHTTP1 types
at the dispatcher boundary; this conversion remains request-time work.

## Optional application modules

Application capabilities may be shipped as separate SwiftPM products in the same repository while they are experimental. Their dependency direction is one-way:

```text
Optional application module
        |
        v
WhiteThroated
        |
        v
WhiteThroatedRuntime -> WhiteThroatedHTTP1 -> SwiftNIO
```

Core targets must never import optional application modules. Importing an optional product must not register middleware, allocate request state, or change transport configuration. Activation is explicit during application setup.

`WhiteThroatedCORS` is the first vertical slice of this boundary. It depends on `WhiteThroated`, installs only through explicit `app.use(cors:)`, and does not add a runtime hook. A request without an `Origin` header immediately delegates to the existing fast-middleware next responder. When CORS response headers are required, prepared responses intentionally become mutable responses because origin-specific headers are request-dependent.

`WhiteThroatedStaticFiles` is the second vertical slice. It also requires no core or runtime hook. A mount compiles an exact GET route plus a terminal catch-all route for its prefix, so requests outside that prefix do not perform static-file policy or filesystem work. Root-directory opening is explicit setup/lifecycle work. Request-time file metadata and open operations run through SwiftNIO's filesystem executor. Path containment is enforced by opening each directory component relative to the previously opened directory handle with symbolic-link following disabled, then opening the final regular file with the same policy. The final descriptor is transferred to a known-length response stream as a `FileRegion` and closed after its flushed write completes.

`WhiteThroatedValidation` is the third vertical slice. It is handler-scoped rather than middleware-scoped and adds no core or runtime hook. Immutable field schemas are built during setup, while path/query/header/cookie lookup and rule evaluation occur only when a handler explicitly requests validation. JSON validation remains lazy: the module checks its configured byte and nesting-depth bounds directly against the existing request `ByteBuffer` before delegating to WhiteThroated's normal `Codable` decoder. Routes that do not call Validation have no Validation dispatch layer or request state.

`WhiteThroatedRateLimit` is the fourth vertical slice. It installs only through explicit fast middleware, keeps its bounded in-process fixed-window state behind a SwiftNIO lock, and requires the application to provide the key resolver. The module does not infer client identity from forwarded headers. Missing/oversized keys are handled by explicit policy, and `maxKeys`/`maxKeyBytes` bound retained state. When accepted-request quota headers are disabled, prepared downstream responses remain prepared; enabling per-request quota headers intentionally materializes a mutable response.


Phase 2 observability remains entirely opt-in. Logging and tracing use fast
middleware and inspect completion without mutating prepared responses. Metrics
requires an allowlisted route-label set and collapses unknown/custom values to
fixed labels so user input cannot create unbounded cardinality. Sampling is
decided before route classification and span identifier generation.

`WhiteThroatedLifecycle` is process-local operational coordination. Its
middleware tracks active requests and rejects new requests after drain begins;
the controller changes readiness before waiting for in-flight work, runs cleanup
callbacks in reverse order, then delegates final server teardown to the existing
`Application.shutdown()`. It adds no runtime-owned application concepts.

The core exposes only read-only `PreparedResponse` status/header/content-length
metadata for observers. This is a value-access surface, not an optional-module
dependency or request-time registry lookup.

## Accepted socket setup

Before installing either HTTP pipeline, `RuntimeServer.configureAcceptedChannel`
sets TCP_NODELAY through NIO's TCP-level `tcpOption` API. Failure propagates to
channel initialization; it is not silently ignored. This work runs once per
accepted connection on its event loop and adds no request-path work. Real-socket
coverage starts the child with TCP_NODELAY disabled and checks that production
setup enables it, so listener inheritance cannot hide an ineffective override.
The raw NIO control uses the same TCP option and failure policy.

## Transport selection

`RuntimeServer` installs `WTHTTP1ConnectionHandler` by default. It combines
the Tier 1 parser and writer with the same prepared, sync, future, and
async/await dispatcher contract. SwiftNIO still owns sockets, event loops,
buffers, and file-region I/O.

If the frozen dispatcher reports any request-streaming routes, the server
installs the stock NIOHTTP1 pipeline plus `RuntimeConnectionHandler` for
every connection. This is an application-wide setup decision, including
ordinary routes and middleware requests, with no per-request transport
switch or replay of partially parsed bytes. Response streaming alone does
not require fallback. Setting `useTier1HTTP1Experimental: false` in the
framework configuration (runtime: `useTier1HTTP1: false`) also selects stock.

The standalone Tier 1 handler still rejects request-streaming actions with
500 without invoking the consumer; production pipeline selection prevents
those applications from reaching it. A declared or incremental body-limit
failure takes precedence. Direct-handler tests retain this fail-safe guard.

Both transports validate outbound header bytes. Tier 1 validation is
differential-tested against the pinned NIO validator and encoder; invalid
headers close the connection. Chunk-extension syntax is checked against
the pinned NIO decoder. Trailer values are validated before discard.

Tier 1 holds out-of-order response heads behind earlier responses. A held
response-stream producer starts only after its head is released. An open
stream gates later responses until its end; head writes remain buffered
until producer flush, flushing write, or completion. File regions remain
`IOData.fileRegion`, including stream chunks. Declared-length tracking and
event-loop checks are shared through `RuntimeStreamWriter`; the stock sink
writes HTTP parts and the Tier 1 sink writes framed bytes.

After a request body is consumed, Tier 1 withholds outbound `read()` calls
and stops dispatching later pipelined requests while a response future or
response stream remains pending. Already received bytes stay in cumulation.
Response completion resumes parsing those bytes before forwarding a pending
read. Body aggregation still permits reads until the current body ends.
A drain reentrancy guard prevents synchronous completion from parsing a
follower before the current request state is reset. Disconnect drops pending
request, response, and stream state. These rules mirror stock pipelining
backpressure and prevent an unbounded queue of completed follower responses
behind one stalled producer.

Fail-safe differences from stock are intentional: CONNECT/bodyless-status
streams suppress the producer, post-end producer writes close the connection,
and recursive invalid-stream error mapping terminates with a fixed 500.
These paths have direct regression coverage alongside byte-equivalence tests.
Stream-validation recursion keys are retained while error mapping is pending
and released once its response head emits; keep-alive errors cannot accumulate
keys for the connection lifetime. Error-handler futures are hopped to the
connection event loop before transport state changes.

## Event-loop model

WhiteThroated uses SwiftNIO event loops as its primary concurrency model.

The stock SwiftNIO HTTP server pipeline keeps outbound response-header validation enabled. Tier 1 applies equivalent byte validation in its writer. Invalid field values such as CR/LF response-splitting attempts are rejected and the connection is closed. WhiteThroated convenience APIs may add stricter validation, but must not disable this transport-level safety boundary.

Rules:

1. Never block an event-loop thread.
2. Do not create a Swift `Task` per request on the default path.
3. Use NIO futures for event-loop-native asynchronous I/O.
4. Offload genuinely blocking work to an appropriate external executor.
5. Keep request-local operations on the current event loop when possible.

The selected connection handler (`WTHTTP1ConnectionHandler` or stock
`RuntimeConnectionHandler`) is instantiated once per channel. Its mutable
request and streaming state is confined to that channel's event loop. The
handlers are `@unchecked Sendable` only so their references can pass through
SwiftNIO's sendable bootstrap APIs; this does not permit arbitrary-thread
access to mutable state. The framework's thin `HTTPServerHandler` test shim
continues to exercise the stock runtime handler. Pipeline-selection and
raw-byte equivalence tests cover Tier 1 and the production installer.

Work leaves the connection event loop only in these documented
cases: an explicit async route future (hopped back before writing),
an async middleware or error-handler future (hopped back the same
way), a streaming consumer future (hopped back before the pump
continues), and a response-stream producer future (hopped back
before the terminal end is written). Synchronous routes never leave
the loop and never create a `Task`, future, or promise.

Transport callbacks that mutate handler or channel state are attached only after the future is known to belong to the channel event loop. WhiteThroated uses SwiftNIO's isolated-future callbacks for those sites. The unsafe-unchecked isolation form is intentional: the event-loop ownership invariant is established by the pipeline or an explicit `hop(to:)`, and avoiding a release-build isolation check keeps the request path allocation- and branch-neutral.

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
- Conversion from `NIOHTTP1.HTTPMethod` to WhiteThroated's public `HTTPMethod`.
- Handler closure invocation.

When middleware exists, WhiteThroated constructs `Request` before the middleware pipeline because middleware is allowed to inspect or transform the request.

`Request` stores the original SwiftNIO HTTP method and converts it to WhiteThroated's public `HTTPMethod` only when application code reads `request.method`. Internal routing uses the original NIO method even when middleware is installed, so middleware does not accidentally force public-method conversion merely to resolve an endpoint. On the middleware-free transport path, matched route parameter metadata is installed during request initialization rather than through follow-up mutation.

## Responder paths

WhiteThroated has three internal response paths.

### Prepared

A `PreparedResponse` is immutable setup-time work.

For HTTP/1.1 keep-alive requests it can reuse:

- Prebuilt body bytes.
- Precomputed content length.
- Precomputed response head.

Prepared routes are stored directly in route endpoints.

A `PreparedResponse` is a small value wrapper around immutable shared storage containing the fallback response, cached HTTP/1.1 head, and cached body buffer. Route endpoints, internal router matches, and responder results carry that storage reference directly. Public middleware wraps it back into `PreparedResponse` only when the middleware API requires the public type.

The built-in 404 response uses process-wide immutable prepared storage. A router miss therefore avoids per-request response-body allocation and serialization while preserving the same public 404 semantics.

### Immediate

A synchronous route returns a `Response` without creating an `EventLoopFuture`.

Synchronous handlers are stored separately from asynchronous handlers in the trie, so they do not pass through an async wrapper.

### Future

Handlers performing asynchronous NIO work return an `EventLoopFuture<Response>`.

`Context` and future allocation are paid only by paths that require them.

Before a route future mutates transport state or writes a response, the writer hops it to the channel event loop. SwiftNIO's `hop(to:)` returns the original future when it is already bound to that loop, so the event-loop-native fast path adds no bridge allocation.

### Async/await

An `AsyncHandler` is an opt-in Swift concurrency path. WhiteThroated bridges it through SwiftNIO's `EventLoopPromise.completeWithTask`.

This path intentionally creates a Swift `Task` for that request. It must never become an implicit wrapper around synchronous, prepared, or NIO-future handlers.

## Connection metadata

`Context.remoteAddress` exposes SwiftNIO's raw peer `SocketAddress`.

The transport passes its `Channel` internally, but reads `channel.remoteAddress` only when a `Context` is actually constructed. Prepared and synchronous routes therefore retain their context-free fast paths.

Middleware, NIO-future handlers, streaming handlers, and application error handlers receive the peer address through their existing `Context`. No reverse-DNS lookup or forwarded-header parsing occurs.


Forwarded client-IP resolution is an explicit opt-in via `ProxyTrustPolicy`.

- The raw socket peer remains authoritative unless that peer is trusted.
- `X-Forwarded-For` is evaluated right-to-left.
- Resolution stops at the first untrusted or malformed hop.
- No forwarded-header work occurs unless application code calls the resolver.
- WhiteThroated does not enable a global "trust all proxies" mode by default.

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

For a canonical static URI, WhiteThroated hashes the path bytes once up to the query marker and performs one exact-table lookup. No `String` is created and route parameters are not involved.

If exact lookup misses, routing falls back to the existing UTF-8 trie. This preserves trailing-slash behavior and mixed static/dynamic route precedence.

`HEAD` lookup order is intentionally:

1. Exact `HEAD` route.
2. `HEAD` trie route.
3. Exact `GET` fallback.
4. `GET` trie fallback.

This prevents an exact `GET` route from incorrectly outranking a dynamic route explicitly registered for `HEAD`.

Static endpoints are duplicated as lightweight setup-time metadata between the exact table and trie. The tradeoff is additional route-table memory in exchange for fewer serving-time lookups on canonical static routes.


The router is method-aware.

Common NIO HTTP methods dispatch directly to dedicated roots. Custom or uncommon methods use the WhiteThroated method mapping and fallback root dictionary.

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

## Cookies

Targeted cookie lookup is lazy. `request.cookie(name)` scans only the Cookie header when called and stops on the first matching name.

Targeted cookie lookup uses contiguous UTF-8 storage with integer-indexed bytes when available, falling back to the zero-copy string UTF-8 view otherwise. Only the matched cookie value is materialized as a `String`.

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

## HTTP/1 framing validation

WhiteThroated validates request framing in the selected decoder: the Tier 1 parser by default, or SwiftNIO's HTTP/1 server pipeline with protocol error handling enabled for the stock fallback. Runtime body-limit enforcement follows decoding on either transport.

Regression tests feed raw HTTP bytes through the same configured pipeline and verify that ambiguous request framing such as simultaneous `Content-Length` plus `Transfer-Encoding`, or invalid duplicate Content-Length syntax, produces a 400 response before a WhiteThroated route is invoked.

WhiteThroated adds only framework-specific body-limit logic after decoding. Its early declared-length comparison is overflow-safe so extremely large decimal Content-Length values can still be rejected before `100 Continue`.

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
- Ordinary and streaming routes share the same overflow-safe declared Content-Length comparator. Values larger than Swift `Int.max` still trigger early 413 instead of falling through the `100 Continue` path.
- Unsupported expectations receive 417 and connection close.
- Early rejection never waits for a request-body end marker that the client may intentionally withhold.

Streaming therefore avoids whole-body aggregation while preserving middleware semantics and backpressure.

## Multipart request bodies

Multipart parsing is an opt-in layer over request-body streaming. It does not change the ordinary aggregated request path or router hot path.

`BodyStreamConsumer.multipart(...)` composes the incremental parser with the throwing synchronous chunk and end responders. Valid multipart chunks therefore create no per-chunk future, while parser errors still propagate through the existing streaming/application error pipeline.

Runtime invariants:

- The complete multipart request body is never intentionally accumulated.
- Part headers are buffered only until `\r\n\r\n` and are capped by `maxHeaderBytesPerPart`.
- Part headers are scanned directly from `ByteBufferView`; WhiteThroated does not construct a full header-block `String` or split it into an intermediate line array.
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
- Parser state is expected to remain confined to the request event-loop flow. The parser is marked `@unchecked Sendable` only so it can be captured by WhiteThroated's `@Sendable` streaming closures without introducing locking on every chunk.
- Multipart parsing should normally use the throwing-synchronous chunk responder so successful parsing does not allocate an `EventLoopFuture` per inbound chunk.
- Client-provided filenames are metadata only and must not be trusted as filesystem paths.

The parser's internal staging buffer can grow to the size of an inbound chunk plus multipart framing state, but it is not a whole-upload accumulator.

## Conditional requests

ETag support is opt-in.

- `EntityTag` validates opaque tag bytes at construction time.
- `request.matchesIfNoneMatch(...)` scans the original HTTP header block directly with an ASCII case-insensitive field-name comparison. It allocates no intermediate header-value array and does not use canonical comma splitting, because commas are valid inside quoted entity-tag opaque values.
- Matching follows weak `If-None-Match` comparison semantics: `W/"tag"` matches `"tag"`.
- Wildcard `*` is supported.
- `Response.notModified(etag:)` emits a bodyless 304 response.
- Prepared responses can attach an ETag during setup while retaining their cached-head path.
- `app.get(path, response: prepared, etag: tag)` compiles two immutable storages at registration: the tagged representation and a bodyless 304 variant.
- With no middleware, a conditional prepared route checks `If-None-Match` directly from `HTTPRequestHead.headers`; it does not construct `Request`, `Context`, a future, or a handler closure invocation.
- The 304 variant preserves representation metadata such as ETag, Cache-Control, Vary, and the original representation Content-Length while carrying no body buffer.

## Byte ranges

Byte-range parsing is opt-in and header-only.

- `request.byteRange(totalLength:)` parses one `bytes` range only when application code asks for it.
- Parsing is byte-oriented and does not split the header into intermediate strings.
- Closed, open-ended, and suffix ranges are supported.
- Multiple ranges are surfaced as `.unsupportedMultiple`; WhiteThroated does not implicitly allocate a multipart/byteranges response.
- `Response.partialFileRegion` constructs a sliced `FileRegion`, preserving zero-copy transport behavior.
- 206 and 416 helpers set the required `Content-Range` and `Accept-Ranges` metadata without filesystem I/O.

## Responses

Ordinary text and byte responses may allocate or serialize per request.

Streaming responses use chunked HTTP/1.1 framing when no `Content-Length` is supplied. When application code explicitly supplies `Content-Length`, WhiteThroated enables byte accounting for that stream only:

- Writes that would exceed the declared length fail before the overflow bytes are written.
- Producer completion with fewer bytes than declared is treated as a framing error.
- Invalid, negative, duplicate, or comma-combined declared lengths fail before the streaming response head is emitted.
- A length mismatch after response streaming begins closes the connection instead of emitting a misleading HTTP end marker.

Unknown-length streams do not allocate or update a length tracker.

`Content-Length` detection scans response headers directly and parses decimal digits from UTF-8 bytes. The success path does not materialize SwiftNIO's canonical header-value array or create an intermediate numeric `String`; duplicate/comma-combined and invalid values allocate diagnostics only on the error path.

`ResponseStreamWriter.write(...)` is a buffered enqueue operation. It writes into the NIO pipeline without installing a per-write completion promise and returns the event loop's cached succeeded `Void` future. This lets producers compose buffered writes with `flatMap` without waiting for a flush that only occurs when the producer completes. `writeAndFlush(...)` remains the explicit API for callers that need a future tied to a flushed transport write.

The framework installs its runtime-stream error mapper once when it creates a
`ResponseStreamWriter`. Declared-length violations are therefore converted to
the public `ResponseStreamError` before their failed future is created. A
successful chunk write returns the transport's original future without adding
an error-mapping future, while foreign producer or channel errors retain their
original identity.

A `Response.fileRegion` body is written as `IOData.fileRegion` directly. WhiteThroated derives content length from the region and does not copy file bytes into a `ByteBuffer`. The caller retains ownership of the underlying file handle and must keep it valid until the write completes.

WhiteThroated must not introduce a convenience API that performs blocking file-open or file-stat work on an event-loop thread.

Use `PreparedResponse` for immutable in-memory payloads where avoiding repeated serialization matters.

Streaming responses are opt-in. WhiteThroated writes the response head, lets the producer emit body chunks on the channel event loop, and writes the terminal HTTP end after the producer future succeeds. The selected transport handles wire framing: the Tier 1 writer emits bytes directly, while the stock sink uses SwiftNIO's HTTP response encoder.

If a streaming producer fails after headers have started, WhiteThroated invokes the optional response-stream error cleanup hook, flushes bytes that were already accepted by the stream writer, and closes the connection rather than attempting to emit a second response or HTTP end marker. The same rule applies when declared Content-Length accounting detects an underflow or overflow after streaming has started. Client disconnects can be observed through the stream writer's close future. HEAD requests suppress the producer. HTTP/1.0 unknown-length streams force connection-close framing unless an explicit content length is supplied.

SSE is implemented as a formatting/header convenience over the same response-stream path. It does not introduce a separate transport abstraction.

WhiteThroated normalizes `Content-Length` from the actual `Response.Body` for every ordinary non-stream response. User-supplied values cannot desynchronize the HTTP/1 keep-alive stream. Prepared-response header mutation applies the same invariant at setup time, so its cached head cannot advertise a length different from its cached body.

304 remains the intentional exception: its body is suppressed while Content-Length may describe the selected representation, as allowed by HTTP semantics. Streaming responses use their separate declared-length tracker.

Prepared bodyless statuses normalize their cached HTTP/1.1 head during setup. Informational responses and 204 remove forbidden framing headers, while 304 may preserve the selected representation's `Content-Length`. On the normal HTTP/1.1 keep-alive path the writer reuses that normalized head directly and emits no body.

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

1. WhiteThroated versus minimal raw SwiftNIO with identical behavior.
2. WhiteThroatedRuntime versus raw SwiftNIO, to separate runtime overhead from framework overhead.
3. WhiteThroated feature deltas, such as prepared versus normal responses.
4. Router depth, fan-out, and parameter-capture scaling.
5. Middleware scaling.
6. ARC and allocation profiling.
7. Cross-framework Swift comparisons.
8. Actix Web comparison.

If WhiteThroated is materially slower than the raw-NIO control, compare the runtime level first: a runtime-vs-raw gap points at the transport port, while a framework-vs-runtime gap points at routing, Request/Response construction, or the dispatcher bridge. Investigate WhiteThroated before blaming Swift.

## Benchmark invariants

Every published result should record:

- WhiteThroated commit SHA.
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


Prepared-response storage normalizes the cached HTTP/1.1 body pointer during application setup. Bodyless statuses and zero-byte payloads carry no writer body buffer, so the HTTP/1.1 prepared writer does not re-check status/body length on every request. Representation metadata such as a 304 Content-Length remains preserved in the cached head.


Keep-alive response completion uses a no-promise write-and-flush fast path. A write future is allocated only when WhiteThroated must wait for the response end to flush before closing a non-persistent connection. This applies to dynamic, bodyless, and response-stream completion paths.


Channel handlers cache whether request-streaming routes exist. When none are registered, request start skips resetting streaming-only state such as pending chunk buffers and streaming futures; ordinary request state is still explicitly initialized on every request.

Dynamic response factories seed Content-Length when the body size is known and mark that framing metadata as normalized. Mutating a Response body or headers invalidates that internal marker automatically. The transport writer therefore skips Content-Length string construction and header scanning for untouched factory responses, while mutated or manually constructed responses still validate and repair stale, missing, or duplicate framing from the actual encoded body length.


The fluent `Response.header(...)` helper consumes its temporary Response value before mutating headers. Swift can therefore preserve unique HTTPHeaders storage for chained response construction, while Copyable value semantics remain unchanged when callers reuse the original response.


For the common dynamic HTTP/1.1 200 path, each channel handler owns a cached `HTTPResponseHead` template and replaces only its headers per request. SwiftNIO stores response status/version in reference-backed private storage, so this avoids allocating that storage for every successful HTTP/1.1 response while non-200 and non-HTTP/1.1 responses keep the general constructor path.


RuntimeConnectionHandler snapshots the dispatcher's middleware and streaming-route feature flags when each channel handler is created. Application configuration is frozen before production child channels are initialized, so these immutable flags do not need to dereference application collections on every request.


The request-head fast path keeps its resolved route action in a local value and only promotes it into general request-lifecycle state for async or streaming fall-through cases. Prepared, synchronous, and not-found responses return without an unnecessary optional action store.


Each connection caches the resolved dispatcher action (prepared storage, sync/async closures, or streaming action) keyed by method+URI. When method and URI match, the request-head fast path dispatches that cached action directly without re-running router lookup. Any cache miss refreshes the cached action, so URI/method changes cannot reuse stale dispatch state.


Bodyless future and Swift-concurrency routes now use the same request-head shortcut as synchronous routes when middleware is absent, no streaming route exists for the method, no Expect header is present, and framing proves the request body is empty. Their response future/task is registered immediately without allocating/resetting the aggregate request lifecycle state; requests with declared or chunked bodies continue through the general path.


For applications with neither middleware nor request-streaming routes, a repeated prepared HTTP/1.1 request with no headers or only Host is handled before general request framing setup. A method+URI+prepared-storage cache hit writes the immutable prepared response immediately; URI or method changes fall back to normal route resolution and refresh the cache.


Short canonical text, HTML, and JSON responses cache complete HTTP/1.1 200 response heads for body lengths through 64 bytes. Response stores only a compact UInt8 cache index; status, header, or body mutation invalidates it. The dynamic writer can therefore reuse the immutable canonical head on persistent HTTP/1.1 responses without enlarging every Response with a cached head object.


Bodyless future routes invoke the cached async action directly with a runtime request and the per-connection remote address; Task/promise creation for Swift-concurrency handlers lives inside the framework's async-action closure. Both paths retain the same future writer, event-loop hop safety, error handling, and framing semantics; middleware, streaming, Expect, and body-bearing requests still use the general pipeline path.


When a canonical short HTTP/1.1 response head is available, the dynamic writer decides that before materializing mutable response headers. The persistent HTTP/1.1 fast path therefore skips the otherwise-unused HTTPHeaders value copy plus framing and connection normalization branches.


Repeated EventLoopFuture routes reuse the cached async action beside the generic route cache. On an exact method+URI hit, bodyless requests invoke that cached action directly with the per-connection remote address, avoiding router re-lookup as well as the middleware-pipeline bridge. URI or method changes refresh or clear the cached action before dispatch.


Canonical short-response metadata also exposes the already-computed UTF-8 byte length from its compact cache index. The persistent HTTP/1.1 text writer uses that byte length for ByteBuffer capacity instead of scanning the String UTF-8 view a second time before serialization.


Synchronous minimal HTTP/1.1 routes try the canonical short-text writer immediately after the handler returns. This skips generic bodyless-status, response-stream, protocol-version, and connection-framing dispatch for the common Response.text/html/json 200 path. Any noncanonical response falls back to the unchanged generic writer.


ResponseStreamWriter string helpers perform the event-loop precondition once before encoding and then use internal checked write helpers. This removes the duplicate inEventLoop branch that previously occurred when writeString delegated back through the public write/writeAndFlush entry points, while preserving content-length tracking and future semantics.


Response.stream(contentLength:) carries the factory-known length beside the producer and marks Content-Length metadata normalized. The stream writer uses that trusted integer directly instead of rescanning and reparsing HTTPHeaders on every response. Any Content-Length/header/body mutation invalidates the normalization bit and falls back to the full duplicate/malformed header validator, preserving framing safety.


Compiled middleware chains now stay in MiddlewareResult form from the router boundary through all registered middleware and convert back to ResponderResult only once at the outer application boundary. Fast middleware therefore passes the next result directly instead of performing ResponderResult → MiddlewareResult → ResponderResult conversions at every layer. Applications with no middleware still use the original InternalHandler terminal directly.

## Process topology and measurement boundaries

Worker processes each own an independent application, runtime and event-loop
group. Configuration freezes separately in each process. Process supervision,
port assignment and load balancing remain deployment responsibilities; the
runtime bootstrap currently exposes no same-port SO_REUSEPORT configuration.
The macOS multi-port findings do not establish Linux accept distribution or
Linux scheduler/cache behavior. See `docs/linux-validation-checklist.md` for
pending topology-transfer controls.

Multi-process recommendations must include aggregate worker memory and CPU,
not just one worker's RSS or tail percentiles. Benchmark shards can now export
raw samples for offline pooled quantiles; mean-of-shard percentiles in earlier
reports remain historical comparison statistics. Neither pooling nor deployment
orchestration changes the framework/runtime bridge or adds request-path work.
