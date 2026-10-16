# WhiteThroated benchmarks

Performance is a product requirement, not a marketing claim.

WhiteThroated keeps benchmark implementation code in Swift. External load generators and profilers may be used from the command line, but their source is not vendored into this repository.

## Source-language policy

Tracked implementation and benchmark source code in this repository must be Swift.

Allowed non-Swift tracked files are documentation and repository metadata such as Markdown, YAML, TOML configuration that is not application source, and ignore files. Benchmark wrappers written in Shell, Python, Lua, Rust, or another implementation language do not belong in this repository.

Cross-framework controls such as Actix Web must live outside the WhiteThroated repository. This keeps the framework itself auditable as a Swift-only codebase while still allowing external comparisons.

## Pinned Swift baseline

The repository runtime baseline is:

- Swift development and benchmark toolchain: 6.4.0.
- Swift Package Manager tools version: 6.1 or newer.
- SwiftNIO: exactly 2.104.0.

Record any external comparison runtime separately with the published result.

## Build and test gate

Before collecting numbers:

```bash
swift package resolve
swift test -c release
swift build -c release --product whitethroated-benchmark-server
swift build -c release --product raw-nio-benchmark-server
swift build -c release --product whitethroated-benchmark-client
```

Do not benchmark a commit that does not pass the release test suite.

CI also runs the committed in-process benchmark matrix with deliberately small iteration counts as a smoke test. The transport writer matrix uses 10,000 iterations so its same-run raw-NIO/framework deltas are less dominated by timer noise while remaining cheap enough for every push. That step verifies that benchmark routes, future callbacks, middleware matrices, router diagnostics, and transport writers remain executable. CI smoke numbers are not performance evidence: GitHub-hosted runners are not pinned hardware, so their ns/op output must not be published or used as a regression threshold.

## In-process core dispatch benchmark

The diagnostic benchmark is implemented in Swift inside `CoreBenchmarkTests`.

Run core dispatch:

```bash
WHITETHROATED_CORE_BENCHMARK=1 \
WHITETHROATED_CORE_ITERATIONS=5000000 \
swift test -c release \
  --filter CoreBenchmarkTests/testCoreDispatchBenchmark
```

It measures:

- prepared exact-static dispatch.
- prepared trie fallback.
- conditional prepared 200 and 304 dispatch.
- synchronous static dispatch.
- already-succeeded event-loop future dispatch, including `Context` construction.
- dynamic parameter capture.
- targeted query and cookie access.
- not-found dispatch.
- lazy HTTP method conversion.

The in-process core benchmark intentionally does not enqueue the async/await `/concurrent` route. Repeating that route without awaiting completion would measure accumulated Swift `Task` backlog rather than request-dispatch cost. Use the network benchmark for the full synchronous versus future versus async/await comparison.

## Router-only benchmark

```bash
WHITETHROATED_ROUTER_CORE_BENCHMARK=1 \
WHITETHROATED_ROUTER_CORE_ITERATIONS=10000000 \
swift test -c release \
  --filter CoreBenchmarkTests/testRouterLookupBenchmark
```

This bypasses transport writes and isolates route lookup behavior, including exact-table hits and misses before trie fallback.

## Middleware scaling benchmark

The middleware matrix is implemented in Swift and shares one zero-layer baseline across both middleware types:

```bash
WHITETHROATED_MIDDLEWARE_BENCHMARK=1 \
WHITETHROATED_MIDDLEWARE_ITERATIONS=1000000 \
swift test -c release \
  --filter CoreBenchmarkTests/testMiddlewareScalingBenchmark
```

It measures:

- 0 middleware layers.
- 1, 4, and 8 synchronous `useFast` pass-through layers.
- 1, 4, and 8 future-based `use` pass-through layers.

The endpoint is the same synchronous plaintext route in every case, so the delta isolates middleware dispatch, `Context` construction, and the future bridge introduced by asynchronous middleware.

## Transport writer benchmark

```bash
WHITETHROATED_TRANSPORT_BENCHMARK=1 \
WHITETHROATED_TRANSPORT_ITERATIONS=500000 \
swift test -c release \
  --filter CoreBenchmarkTests/testTransportWriterBenchmark
```

This compares the following transport paths through an active `EmbeddedChannel`:

- minimal raw SwiftNIO writer with a cached HTTP/1.1 head and body and no framework routing.
- the same raw writer rebuilding an `HTTPResponseHead` from cached headers on every request, isolating SwiftNIO response-head construction cost.
- direct WhiteThroated prepared dispatch with the per-connection last-route cache, bypassing the full request lifecycle state machine.
- the same direct prepared dispatch with a fresh exact-table lookup on every request, isolating whether method+URI cache validation is cheaper than exact-static routing.
- prepared 200 with a cached HTTP/1.1 head and body buffer through the full `HTTPServerHandler`.
- conditional prepared 304 with a cached normalized bodyless HTTP/1.1 head.
- the same prepared GET in an application that also has a POST streaming route.
- the same prepared GET in an application that also has an unrelated GET streaming route.
- ordinary synchronous text 200 whose factory already carries the exact Content-Length.
- the same factory response with a Date header added through the fluent `.header(...)` API.
- an identical response using mutating `setHeader(...)`, isolating fluent-copy versus in-place header mutation cost.
- the same synchronous text response with Content-Length omitted, forcing writer-side framing insertion.
- the same synchronous text response with a stale Content-Length, forcing writer-side framing repair.
- synchronous pre-buffered 200 with the same payload/content type, isolating text encoding/allocation from dynamic response-header work.
- synchronous dynamic-parameter echo using positional parameter access, covering the external `GET /user/:id` response shape through the full writer.
- already-succeeded event-loop future 200 on the request-head bodyless shortcut.
- the same future handler behind a zero-chunk `Transfer-Encoding: chunked` request, forcing the general request lifecycle path without changing the response payload.

The two streaming-feature cases measure request-streaming feature tax separately from response writing. Streaming bookkeeping is scoped to HTTP methods that actually have streaming routes: an unrelated POST streaming route must not tax an ordinary GET, while a GET streaming route still exercises the method-local streaming machinery.

The fluent and mutating Date-header cases produce identical status, headers, and body. The benchmark emits paired `header-chain` and `header-mutating` medians across alternating orders so the delta isolates response-copy/header COW behavior rather than wire serialization.

The exact, missing, and stale Content-Length synchronous cases use the same text payload and content type. Their delta isolates the cost of preserving normalized header storage versus mutating HTTPHeaders during framing repair. The benchmark also emits `framing-exact`, `framing-missing`, and `framing-stale` medians from six rotated/reversed rounds in the same process, reducing bias from runner drift and benchmark ordering. Short canonical text, HTML, and JSON factories reuse immutable prebuilt header blocks for body lengths through 64 bytes; Swift Array copy-on-write keeps later response-header mutation isolated while removing repeated header-array construction from the common short-response path.

The raw cached-head writer, raw dynamic-head writer, direct prepared writers, and full prepared writer use the same `/prepared` request target and identical response payload/content headers. The `route-cache` and `route-lookup` paired medians alternate measurement order in one process, so the per-connection method+URI cache can be kept only when it actually beats a fresh exact-static lookup. The `match-cache` and `storage-cache` pair then isolates the extra cost of retaining a generic `RouterMatch` and pattern-matching it on every repeated prepared request versus retaining the already-resolved `PreparedResponseStorage` reference directly. The `future-head` and `future-general` paired medians use the same succeeded-future handler and response; only request framing differs, isolating the bodyless request-head shortcut from the aggregate request lifecycle. The raw cached-to-dynamic delta isolates per-request `HTTPResponseHead` construction before framework routing is involved. The matrix also emits `head-cached` and `head-dynamic` medians from alternating rounds so allocation cost is not inferred from one fixed benchmark order. The direct prepared writer and the production `HTTPServerHandler` both retain the previous method + URI match per connection, mirroring high-locality HTTP/1.1 keep-alive traffic without introducing global synchronization. After warm-up, the raw-to-direct delta therefore isolates the cached framework match dispatch and prepared writer, while the direct-to-full delta isolates the request lifecycle state machine around the same cached route. A changed method or URI invalidates the per-connection match and performs a normal router lookup. For requests whose framing proves that the body is empty (no Transfer-Encoding and either no Content-Length or a single exact zero Content-Length), the production transport dispatches directly from the request-head event instead of waiting for the redundant end event. Prepared bodyless routes with no middleware, streaming route for the method, or Expect header take an earlier shortcut that writes the cached prepared response before allocating/resetting the ordinary request lifecycle state. Non-prepared bodyless routes still use the general head-dispatch path. Requests with a declared or chunked body continue through the normal aggregation/streaming path. The raw SwiftNIO network control and the raw/direct in-process transport controls use the same bodyless head-dispatch timing so the framework is not compared against an artificially slower control. On the common HTTP/1.1 path with no Connection header, both the production transport and raw SwiftNIO control resolve keep-alive directly from the protocol version; requests carrying a Connection header still delegate to SwiftNIO's canonical token semantics. The channel is activated before warm-up and timing so asynchronous writer callbacks see the same active-connection invariant as production. The prepared 304 case specifically measures the bodyless writer path after setup-time removal of forbidden framing headers.

Repeated synchronous requests retain their handler and captured parameter metadata beside the generic per-connection RouterMatch. When method and URI are identical, the request-head fast path constructs the public Request and invokes the handler directly, avoiding another RouterMatch copy and pattern match. Cache misses refresh or clear both prepared and synchronous side caches so stale handlers or parameter ranges cannot cross request targets.

Treat these in-process measurements as diagnostic ns/op data. They are not substitutes for network measurements.

## WhiteThroated network benchmark server

Start WhiteThroated in release mode:

```bash
WHITETHROATED_HOST=127.0.0.1 \
WHITETHROATED_PORT=3000 \
WHITETHROATED_THREADS=4 \
swift run -c release whitethroated-benchmark-server
```

Core routes include:

- `GET /` — empty prepared 200 used by the external framework contract.
- `GET /user/:id` — echoes one dynamic parameter for the external framework contract.
- `POST /user` — empty prepared 200 used by the external framework contract.
- `/prepared` — prepared immutable plaintext.
- `/plaintext` — ordinary synchronous plaintext.
- `/future` — future-based plaintext using an already-succeeded event-loop future.
- `/json` — synchronous JSON.
- `/concurrent` — async/await plaintext through the Swift concurrency Task bridge.
- `/users/:id` — one dynamic parameter.
- `/users/:id/posts/:post` — two dynamic parameters.
- `/conditional-prepared` — conditional prepared ETag path.

The default server registers no request-streaming route. Upload and multipart streaming routes remain opt-in so the baseline transport path is not charged request-streaming bookkeeping merely because benchmark-only feature routes exist.

WhiteThroated also ships a SwiftNIO benchmark client, so raw-NIO and framework network throughput can be compared without vendoring `wrk`, Python, or shell benchmark code.

With either benchmark server already running:

```bash
WHITETHROATED_BENCH_HOST=127.0.0.1 \
WHITETHROATED_BENCH_PORT=3000 \
WHITETHROATED_BENCH_METHOD=GET \
WHITETHROATED_BENCH_PATH=/prepared \
WHITETHROATED_BENCH_CONNECTIONS=128 \
WHITETHROATED_BENCH_REQUESTS=1000000 \
swift run -c release whitethroated-benchmark-client
```

The client opens all connections before starting the timer and keeps exactly one request in flight per connection. Connection establishment is therefore excluded from measured throughput, and raw-NIO/WhiteThroated comparisons use the same HTTP client implementation. `WHITETHROATED_BENCH_METHOD` selects the request method and defaults to `GET`, which allows the same client to exercise the external `GET /`, `GET /user/:id`, and `POST /user` contract without changing source. `WHITETHROATED_BENCH_THREADS` can override the client event-loop thread count. `WHITETHROATED_BENCH_TCP_NODELAY=0` disables the client-side TCP_NODELAY socket option for restricted or diagnostic environments; keep the same setting across compared servers. Connection-close errors report completed versus target requests for the failed connection. The client always reports completed requests, requests per second, response-body bytes, and response-body MiB/s. Body throughput intentionally excludes HTTP framing/header bytes; use the same response payload and headers when comparing servers.

Set `WHITETHROATED_BENCH_LATENCY=1` to collect per-request cycle latency after the first request on each connection. The client reports minimum, average, p50, p75, p90, p99, p99.999, and maximum microseconds. Latency samples are sorted only after the throughput timer stops; timestamp collection itself remains part of the measured client workload, so use the same latency setting on every server being compared.

For the external concurrency matrix, run separate throughput-only and latency-enabled samples at 64, 256, and 512 concurrent connections. The throughput-only sample is the primary RPS result; the latency-enabled sample is the paired distribution result.

For a raw lower-bound comparison, run `raw-nio-benchmark-server` with the same server thread count, port, client connection count, and total request count. The raw server implements `GET /prepared` plus the external `GET /`, `GET /user/:id`, and `POST /user` contract, so each framework route can be compared against a minimal SwiftNIO control with matching response semantics. The client is intended for comparative loopback or separate-host diagnostics; use an independent load generator as an additional validation before publishing benchmark claims.

## External leaderboard contract

For cross-framework validation, use the same three-route contract as the public benchmark harness:

- `GET /` returns an empty 2xx response.
- `GET /user/:id` returns the route parameter as the response body.
- `POST /user` returns an empty 2xx response.

Run the external closed-loop load generator at concurrency 64, 256, and 512 with identical load-generator threads, duration, timeout, CPU allocation, operating system, HTTP version, keep-alive behavior, and response semantics for every framework. Treat all three concurrency levels as independent acceptance gates: a change is not a cross-framework win if it raises peak throughput while regressing tail latency at another level.

Do not compare WhiteThroated's specially prepared `/prepared` diagnostic route against another framework's dynamic benchmark route. The external contract must be compared route-for-route.

## Middleware measurements

The benchmark server can compile pass-through middleware layers into the same Swift server:

```bash
WHITETHROATED_FAST_MIDDLEWARE_LAYERS=4 \
WHITETHROATED_THREADS=4 \
swift run -c release whitethroated-benchmark-server
```

For future-based middleware:

```bash
WHITETHROATED_ASYNC_MIDDLEWARE_LAYERS=4 \
WHITETHROATED_THREADS=4 \
swift run -c release whitethroated-benchmark-server
```

Measure 0, 1, 4, and 8 layers with identical external load settings.

## Feature-specific benchmark routes

Feature matrices remain implemented in the Swift benchmark server and are opt-in so they do not contaminate the default route table.

Enable request streaming:

```bash
WHITETHROATED_UPLOAD_BENCHMARKS=1 \
swift run -c release whitethroated-benchmark-server
```

Enable response streaming:

```bash
WHITETHROATED_RESPONSE_STREAM_BENCHMARKS=1 \
swift run -c release whitethroated-benchmark-server
```

Enable router stress routes:

```bash
WHITETHROATED_ROUTER_BENCHMARKS=1 \
swift run -c release whitethroated-benchmark-server
```

Enable multipart routes:

```bash
WHITETHROATED_MULTIPART_BENCHMARKS=1 \
swift run -c release whitethroated-benchmark-server
```

Enable the larger conditional-response matrix:

```bash
WHITETHROATED_CONDITIONAL_BENCHMARKS=1 \
swift run -c release whitethroated-benchmark-server
```

Payload generation and network orchestration for these cases should be performed by an external benchmark harness so WhiteThroated remains Swift-only.

## Raw SwiftNIO control

Start the minimal SwiftNIO control with the same worker count:

```bash
WHITETHROATED_HOST=127.0.0.1 \
WHITETHROATED_PORT=3000 \
WHITETHROATED_THREADS=4 \
swift run -c release raw-nio-benchmark-server
```

The control is intentionally a transport lower bound rather than a router benchmark: every GET path returns the same fixed `Hello, World!` response. Its payload, content type, content length, fixed Date header, HTTP/1.1 pipeline, socket options, and pipelining assistance match WhiteThroated's prepared baseline.

Always send the exact same request target to both processes. For example, compare raw SwiftNIO `/prepared` against WhiteThroated `/prepared`, then raw SwiftNIO `/plaintext` against WhiteThroated `/plaintext`. This keeps URI bytes identical while making the raw control a strict lower bound that does no framework routing.

Use the same host, worker count, load-generator threads, connections, duration, warm-up, and HTTP version for both runs.

## Actix Web comparison

Actix is an external control and is intentionally not implemented or vendored in this repository.

When comparing against Actix:

1. Pin the Rust and Actix versions in the benchmark record.
2. Match the response body and relevant headers.
3. Disable unrelated features such as compression and HTTP/2 when comparing the HTTP/1.1 plaintext path.
4. Use the same physical machine and load settings.
5. Run WhiteThroated-to-raw-SwiftNIO first so Swift framework overhead is understood before interpreting Swift-vs-Rust results.

Do not copy Rust source into this repository solely to make the comparison convenient.

## Linux profiling

External profiling tools are allowed because they are runtime tools, not repository implementation source.

Useful `perf stat` counters include:

- task clock.
- CPU cycles.
- instructions.
- branches and branch misses.
- cache references and misses.
- context switches.
- CPU migrations.
- page faults.

Profile at least:

- `/prepared`.
- `/plaintext`.
- `/future`.
- `/concurrent`.
- `/users/42`.

Use profiling to explain benchmark deltas, not as the throughput result itself.

## Comparison protocol

For any publishable comparison:

1. Use the same physical machine.
2. Pin release or optimized builds.
3. Record exact compiler and dependency versions.
4. Use the same response bytes and relevant headers.
5. Use the same HTTP version and keep-alive behavior.
6. Use the same worker count, benchmark threads, connections, and duration.
7. Warm each server.
8. Collect multiple samples.
9. Record CPU and resident memory.
10. Compare minimum, average, p50, p75, p90, p99, and p99.999 latency in addition to requests per second.
11. Compare WhiteThroated against raw SwiftNIO before attributing a delta to Swift.
12. Do not tune only one side.

Record at minimum:

- requests per second.
- minimum latency.
- average latency.
- p50 latency.
- p75 latency.
- p90 latency.
- p99 latency.
- p99.999 latency.
- maximum latency.
- transfer rate.
- CPU utilization.
- resident memory.
- Swift version.
- SwiftNIO version.
- external framework/compiler versions when applicable.
- operating system.
- CPU model.
- benchmark command.
- commit SHA.

## Validation order

The most informative order is:

1. Raw SwiftNIO versus WhiteThroated `/prepared`.
2. Run the external three-route contract at concurrency 64, 256, and 512, collecting throughput-only and paired latency-distribution samples.
3. WhiteThroated `/prepared` versus `/plaintext`.
4. Compare `/plaintext`, `/future`, and `/concurrent` under identical load. The first delta exposes the future-based handler cost; the second shows the additional Swift concurrency bridge cost relative to the NIO-future path.
5. Router-only exact-hit and exact-miss diagnostics.
6. Fast and future-based middleware scaling.
7. Response-stream known-length, chunked, and flush-heavy paths.
8. Aggregated versus streaming request-body throughput and memory.
9. Multipart parser overhead over the raw streaming path.
10. ARC/allocation profiling for unexplained deltas.
11. External Actix comparison after the Swift-side overhead is understood.

No performance number should be published without its environment, command, raw samples, and commit SHA.
