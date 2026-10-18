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
swift build -c release --product custom-http1-benchmark-server
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
- dynamic parameter capture, including router-provided percent-decoding hints that let ordinary unescaped parameters skip a second byte scan on access.
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

- raw SwiftNIO empty 200 versus WhiteThroated prepared empty 200 using a Host-only HTTP/1.1 request, matching the external `GET /` contract.
- minimal raw SwiftNIO writer with a cached HTTP/1.1 head and body and no framework routing.
- the same raw writer rebuilding an `HTTPResponseHead` from cached headers on every request, isolating SwiftNIO response-head construction cost.
- direct WhiteThroated prepared dispatch with the per-connection last-route cache, bypassing the full request lifecycle state machine.
- the same direct prepared dispatch with a fresh exact-table lookup on every request, isolating whether method+URI cache validation is cheaper than exact-static routing.
- prepared 200 with a cached HTTP/1.1 head and body buffer through the full runtime connection handler (driven via the framework's `HTTPServerHandler` test shim).
- conditional prepared 304 with a cached normalized bodyless HTTP/1.1 head.
- the same prepared GET in an application that also has a POST streaming route.
- the same prepared GET in an application that also has an unrelated GET streaming route.
- raw SwiftNIO dynamic text 200 that allocates and UTF-8 encodes the same "Hello, World!" body on every request while reusing the canonical HTTP/1.1 response head.
- ordinary synchronous text 200 whose factory already carries the exact Content-Length.
- the same factory response with a Date header added through the fluent `.header(...)` API.
- an identical response using mutating `setHeader(...)`, isolating fluent-copy versus in-place header mutation cost.
- the same synchronous text response with Content-Length omitted, forcing writer-side framing insertion.
- the same synchronous text response with a stale Content-Length, forcing writer-side framing repair.
- synchronous pre-buffered 200 with the same payload/content type, isolating text encoding/allocation from dynamic response-header work.
- raw SwiftNIO `/user/:id` prefix extraction plus dynamic body/header writer matching the external contract control.
- synchronous dynamic-parameter echo using positional parameter access, covering the external `GET /user/:id` response shape through the full writer.
- already-succeeded event-loop future 200 on the request-head bodyless shortcut.
- the same future handler behind a zero-chunk `Transfer-Encoding: chunked` request, forcing the general request lifecycle path without changing the response payload.
- known-length response streaming split into two text writes.
- unknown-length HTTP/1.1 response streaming with the same two writes.
- the same unknown-length stream with an explicit flush after the first chunk.

The two streaming-feature cases measure request-streaming feature tax separately from response writing. Streaming bookkeeping is scoped to HTTP methods that actually have streaming routes: an unrelated POST streaming route must not tax an ordinary GET, while a GET streaming route still exercises the method-local streaming machinery.

The fluent and mutating Date-header cases produce identical status, headers, and body. The benchmark emits paired `header-chain` and `header-mutating` medians across alternating orders so the delta isolates response-copy/header COW behavior rather than wire serialization.

The `canonical-head` and `rebuilt-head` paired medians return the same status, headers, and text body. The rebuilt case assigns `.ok` to an already-`.ok` response solely to invalidate internal canonical-head metadata. Canonical short text responses on persistent HTTP/1.1 take a direct writer path that reuses the cached response head and skips generic body/header/framing dispatch; the paired median therefore isolates the complete canonical fast path from normal dynamic response construction.

The exact, missing, and stale Content-Length synchronous cases use the same text payload and content type. Their delta isolates the cost of preserving normalized header storage versus mutating HTTPHeaders during framing repair. The benchmark also emits `framing-exact`, `framing-missing`, and `framing-stale` medians from six rotated/reversed rounds in the same process, reducing bias from runner drift and benchmark ordering. Short canonical text, HTML, and JSON factories reuse immutable prebuilt header blocks for body lengths through 64 bytes; Swift Array copy-on-write keeps later response-header mutation isolated while removing repeated header-array construction from the common short-response path.

The raw cached-head writer, raw dynamic-head writer, direct prepared writers, and full prepared writer use the same `/prepared` request target and identical response payload/content headers. The `route-cache` and `route-lookup` paired medians alternate measurement order in one process, so the per-connection method+URI cache can be kept only when it actually beats a fresh exact-static lookup. The `match-cache` and `storage-cache` pair then isolates the extra cost of retaining a generic `RouterMatch` and pattern-matching it on every repeated prepared request versus retaining the already-resolved `PreparedResponseStorage` reference directly. The `future-head` and `future-general` paired medians use the same succeeded-future handler and response; only request framing differs, isolating the bodyless request-head shortcut from the aggregate request lifecycle. The future dispatch trio separates three costs while keeping the same future callback and dynamic response serialization: `future-bridge` retains the cached generic match and Application/ResponderResult bridge, `future-match-direct` retains the generic match but invokes the extracted handler directly, and `future-handler-cache` retains the resolved handler plus parameter metadata directly. The raw cached-to-dynamic delta isolates per-request `HTTPResponseHead` construction before framework routing is involved. The matrix also emits `head-cached` and `head-dynamic` medians from alternating rounds so allocation cost is not inferred from one fixed benchmark order. The direct prepared writer and the production runtime connection handler both retain the previous method + URI dispatch action per connection, mirroring high-locality HTTP/1.1 keep-alive traffic without introducing global synchronization. After warm-up, the raw-to-direct delta therefore isolates the cached framework match dispatch and prepared writer, while the direct-to-full delta isolates the request lifecycle state machine around the same cached route. A changed method or URI invalidates the per-connection match and performs a normal router lookup. For requests whose framing proves that the body is empty (no Transfer-Encoding and either no Content-Length or a single exact zero Content-Length), the production transport dispatches directly from the request-head event instead of waiting for the redundant end event. Prepared bodyless routes with no middleware, streaming route for the method, or Expect header take an earlier shortcut that writes the cached prepared response before allocating/resetting the ordinary request lifecycle state. Non-prepared bodyless routes still use the general head-dispatch path. Requests with a declared or chunked body continue through the normal aggregation/streaming path. The raw SwiftNIO network control and the raw/direct in-process transport controls use the same bodyless head-dispatch timing so the framework is not compared against an artificially slower control. On the common HTTP/1.1 path with no Connection header, both the production transport and raw SwiftNIO control resolve keep-alive directly from the protocol version; requests carrying a Connection header still delegate to SwiftNIO's canonical token semantics. The channel is activated before warm-up and timing so asynchronous writer callbacks see the same active-connection invariant as production. The prepared 304 case specifically measures the bodyless writer path after setup-time removal of forbidden framing headers.

Repeated synchronous requests retain their handler and captured parameter metadata beside the generic per-connection RouterMatch. The side cache is keyed by exact method + URI, not only by route template: repeated requests construct the public Request and invoke the handler directly, while a changed target refreshes or clears the side cache before dispatch. This avoids repeated RouterMatch copying and pattern matching without allowing stale parameter ranges to cross request targets.

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

For a raw lower-bound comparison, run `raw-nio-benchmark-server` with the same server thread count, port, client connection count, and total request count. The raw server implements `GET /prepared` plus the external `GET /`, `GET /user/:id`, and `POST /user` contract, so each framework route can be compared against a minimal SwiftNIO control with matching response semantics. Its dynamic parameter route uses the same short-response header-cache strategy and reusable HTTP/1.1 response-head template as WhiteThroated, preventing the raw control from being artificially penalized by repeated header-array and response-head storage construction. The client is intended for comparative loopback or separate-host diagnostics; use an independent load generator as an additional validation before publishing benchmark claims.

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

## WhiteThroatedRuntime benchmark server

Start the runtime-level server with the same worker count:

```bash
WHITETHROATED_HOST=127.0.0.1 \
WHITETHROATED_PORT=3000 \
WHITETHROATED_THREADS=4 \
swift run -c release whitethroated-runtime-benchmark-server
```

This server drives `WhiteThroatedRuntime` through a hand-built dispatcher with no `Application`, no framework router, no middleware, and no Request/Response types. It implements the same external `GET /`, `GET /user/:id`, `POST /user` contract, so the three-way comparison raw-vs-runtime-vs-framework separates transport overhead (runtime minus raw) from framework overhead (framework minus runtime). When framework throughput regresses against raw, check the runtime level first: a runtime-vs-raw gap points at the transport port, while a framework-vs-runtime gap points at routing, Request/Response construction, or the dispatcher bridge.

## Multi-process topology

Eight single-loop server processes behind a sharding client show tighter tails than one eight-loop process under the same total load (3 interleaved rounds, matched 8-client apparatus, 1M requests per cell): p90 improves 3–13% and p99 improves 13–20% across `GET /` c64/c256 and `GET /user/42` c256, with neutral p50 and neutral-to-better throughput. Dose-response is monotonic with diminishing returns: 4×2-loop processes roughly match 8×1, both clearly beat 2×4, which beats 1×8 on p90/p99 at fixed total loops. The win transfers to the framework server (2 interleaved rounds, same apparatus): p90 −3–15%, p99 −18–34% for 8×1 versus 1×8, with neutral-to-better throughput. This is a topology correlation; allocator and scheduler causality, and the residual competitor gap, require separate evidence.

Two macOS caveats. First, plain `SO_REUSEPORT` multi-binds successfully but delivers every TCP accept to one socket (measured 256/0/0/0/0/0/0/0 across eight workers); macOS has no `SO_REUSEPORT_LB` equivalent, so single-port multi-process serving needs userspace distribution or per-worker ports behind a load balancer. Second, mean-of-shard percentiles are a comparison metric only: they overstate shard-local stalls relative to pooled percentiles, so always compare topologies through the identical sharded apparatus rather than against single-client runs.

Framework topology × memory (`GET /` c256, identical 8-shard apparatus, 2 rotated rounds; see `docs/benchmark-topology-memory-2026-10-17.md`): RPS improves monotonically to +7.3% at 8×1 and p90 to −11.0%, both monotonic within each round — reproducing the transfer finding. Memory scales near-linearly (post-load 13.0 → 20.5 → 37.2 → 71.0 MB; peak ≈ post, no spikes) while total CPU is flat (~240%), so 8×1 gains +7% requests-per-CPU-second at +58 MB. Two caveats from a marginal window (pressure/load recorded): p99 sat at the ~18 ms machine-noise floor for all topologies and did not reproduce the prior −18 to −34% transfer win — conflicting data point, needs quiet-window adjudication, prior finding neither confirmed nor overturned; p50 slightly favors 1×8 (+5–16%, "mixed", needs quiet confirmation). 4×2 (+5.9% RPS, −6.5% p90, +24 MB) is the current sweet spot pending p99 adjudication.

Scheduler evidence (`GET /` c256, same 8-shard apparatus, 2 rotated rounds, `getrusage(RUSAGE_CHILDREN)` per worker set; see `docs/benchmark-topology-scheduler-2026-10-17.md`): the p90 win (−10.2%, monotonic both rounds, third reproduction) accompanies −15.1% user CPU (monotonic both rounds; idle dilution means the load-phase gap is larger) with context-switch activity flat (±6% inside ±8% round spreads) and system CPU ~flat — so scheduler *quantity* is rejected as the tail mechanism on macOS and the lead redirects to user-space efficiency (cache locality / coherence / allocator fast-path, unproven; Linux `perf` IPC/stall/cache-miss counters are now the priority over switch counts). macOS cannot split voluntary/involuntary switches via this API (validated: a pure-`sleep` child reports nvcsw=0) nor report migrations — those are Linux-only. p99 flat again at the ~17–18 ms machine floor; p50 flat-ish.

Measured nulls (2026-10-17, M1 Pro): mimalloc v3.5.4 via `DYLD_INSERT_LIBRARIES`, kept outside the repository, moved tails ±8% mixed on both the runtime and framework servers, so allocator contention is rejected as the tail driver and the system allocator stands. Interposition was verified genuinely active via `vmmap` (dylib mapped in the server process) plus mimalloc's own verbose init banner, so this is a true null, not a silently ignored `DYLD_INSERT_LIBRARIES`. A fixed 2048-byte receive buffer versus the adaptive recv allocator flipped between rounds (null, reverted), and a `consuming` body conversion measured null in-process (reverted). None of these need re-trialling without new profiling evidence.

Matched small-JSON matrix (`GET /json`, 27-byte body, 5 servers × c64/c256/c512, 1M requests/cell, RPS median-of-3, latency mean-of-2; see `docs/benchmark-json-whitethroated-hono-express-2026-10-17.md`): WhiteThroated beats Hono/Bun on RPS/avg/p50/p75 in all 12 cells (+35–43% RPS) and loses p90/p99 in all 6 cells (+23–30% p90, +107–126% p99); Express on Bun trails on throughput, average, p50, p75 and p90 but beats WhiteThroated at p99 in all three cells. Same verdict shape as the empty-body matrix, so the tail gap is workload-independent. New: Hono's run-to-run percentile spread is ±0.4–4% versus typically ±4–15% Swift-side — a tail-variance gap, not just a tail-level gap. Resolved as a standing small cost, not a regression (see `docs/benchmark-json-isolation-2026-10-17.md`): a rotated-order 5-round isolation (70 cells, quiet window, control `/` at 99.9/96.8%) shows framework ≈ raw on empty responses and trailing ~2–8% on non-empty responses (`/prepared`, `/json`), order-independent and consistent with the base report's own worst cells (already body routes). Prepared-vs-dynamic parity on identical bytes (±1.2%) exonerates response construction; `PreparedResponse` pre-buffers its body and conversion is shallow, so the residual is dispatch + conversion object work at the apparatus resolution limit. First attempt (42 cells) was inconclusive — the `/` control read −9.2% under host-side load with fixed server order — which motivated the strengthened protocol (machine pre-flight, rotated order, five rounds) now required for any sub-10% claim.

## Custom HTTP/1 transport experiment

The repository includes an experimental benchmark-only server that removes
`NIOHTTP1` from the server transport path while retaining `NIOCore` and
`NIOPosix`:

```bash
swift build -c release --product custom-http1-benchmark-server

WHITETHROATED_HOST=127.0.0.1 \
WHITETHROATED_PORT=3000 \
WHITETHROATED_THREADS=4 \
.build/release/custom-http1-benchmark-server
```

The experiment implements the same benchmark contract used by the raw-NIO
control for `GET /`, `GET /prepared`, `GET /json`, `GET /user/:id`,
and `POST /user`. It parses request bytes directly from `ByteBuffer` and
writes HTTP/1.1 response bytes directly to the channel. The executable target
depends on `NIOCore` and `NIOPosix`, not `NIOHTTP1`.

This is an isolation experiment, not a production transport. It intentionally
accepts only the HTTP/1.1 subset exercised by the benchmark contract:
Content-Length request bodies are supported, while Transfer-Encoding and
Expect are rejected rather than implementing chunked decoding or
100-continue. The parser requires Host, rejects duplicate Content-Length,
rejects ambiguous framing, bounds request headers at 16 KiB and request bodies
at 16 MiB, handles fragmented reads, and can consume multiple complete
requests from one inbound buffer. The benchmark client remains closed-loop
with one request in flight per connection, so lack of NIO HTTP pipelining
assistance does not change the measured contract.

Use the existing campaign harness so thread count, warm-up, routes,
concurrency, request counts, latency collection, resource observation and
HTTP verification remain identical:

```bash
swift build -c release --product custom-http1-benchmark-server
swift build -c release --product whitethroated-benchmark-client
swift build -c release --product whitethroated-benchmark-campaign

WHITETHROATED_CAMPAIGN_SERVER=custom-http1-benchmark-server \
WHITETHROATED_CAMPAIGN_HTTP1_EXPERIMENT=1 \
WHITETHROATED_CAMPAIGN_OUTPUT=/tmp/custom-http1-campaign \
.build/release/whitethroated-benchmark-campaign
```

With `WHITETHROATED_CAMPAIGN_HTTP1_EXPERIMENT=1`, the campaign keeps the
historical `GET /`, `GET /user/42`, and `POST /user` cells and adds
`GET /prepared` plus `GET /json`. The profile is accepted only for the
raw-NIO and custom-HTTP/1 controls so the isolation question stays narrow.
Run the raw-NIO archive with the same flag, topology, concurrency matrix,
request counts and quiet-host gates.

Compare that archive against a fresh `raw-nio-benchmark-server` campaign on
the same quiet host. A result is evidence only about the cost of the
`NIOHTTP1` parser/encoder plus surrounding pipeline behavior under this
specific HTTP/1.1 contract. It is not evidence that a production replacement
for `NIOHTTP1` is safe or faster until chunked framing, Expect handling,
HTTP/1.0 semantics, parser adversarial tests, and equivalent production
correctness are implemented and validated.

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


The raw SwiftNIO network control recognizes the same minimal HTTP/1.1 request shape as WhiteThroated: no headers or a single case-insensitive Host header implies an empty body and persistent connection. This avoids giving WhiteThroated an artificial advantage from framing/header scans that the raw lower bound can also eliminate.


The `param-raw` and `param-framework` paired medians use the same `/user/42` request and dynamic text response shape. This exposes the full framework tax for trie parameter capture, Request construction, positional parameter access, Response construction, and dynamic writing relative to the raw external-contract implementation.


The `empty-raw` and `empty-framework` paired medians model the public `GET /` contract with the same Host-only HTTP/1.1 request and Content-Length: 0 response. The raw control validates HTTP/1.1, GET, the exact root URI, and the case-insensitive single Host header before writing its cached head, so this comparison includes equivalent request-contract checks instead of using an artificially branchless raw writer.


The `text-raw` and `text-framework` paired medians both allocate a ByteBuffer and UTF-8 encode the same short text body per request while reusing an equivalent canonical HTTP/1.1 response head. The raw control also validates HTTP/1.1, GET, the exact `/plaintext` URI, and the same minimal zero/Host-only header shape before writing, so it remains a strict but structurally fair lower bound. Their delta isolates WhiteThroated's Request construction, cached synchronous handler dispatch, Response.text factory, and dynamic writer orchestration without giving the raw control a pre-buffered body or branchless request-contract advantage.


The `stream-length-trusted` and `stream-length-header` paired medians emit identical known-length responses with identical two-write producers. The first uses the `contentLength:` factory parameter and trusted internal metadata; the second adds the same Content-Length through the response header API and therefore exercises the full header scan/parser. Their delta isolates redundant framing metadata recovery from the rest of known-length stream accounting.

The `stream-known`, `stream-chunked`, and `stream-flush` transport cases run the EmbeddedEventLoop after request dispatch so producer completion and final response-end callbacks are included in the measurement. They use the same 13-byte payload split into two writes; the matrix therefore exposes known-length tracking, unknown-length framing setup, and explicit flush cost separately.


The `request-copy` and `request-consume` paired medians feed identical owned HTTPRequestHead values through the same synchronous handler and canonical text writer. The only intentional difference is whether Request copies the head-backed URI/header storage or consumes the inbound head into Request, providing evidence before ownership semantics are introduced into the production fast path.


The `text-factory` and `text-shared` paired medians use the same synchronous route cache and canonical text writer. The factory case constructs Response.text on every request; the shared case returns an immutable captured Response with identical status, headers, and body. Their delta isolates short-response factory/header metadata construction from Request dispatch and body serialization.


CI transport diagnostics use 50,000 iterations per sample while router, middleware, and generic core smoke benchmarks remain at 10,000. Transport paired benchmarks already rotate/reverse ordering; the larger sample reduces timer and scheduler noise for the sub-microsecond deltas now being optimized.

## Exact pooling of client shards

The release client supports optional `WHITETHROATED_BENCH_OUTPUT=/absolute/path.json`
and requires a nonempty `WHITETHROATED_BENCH_RUN_ID` when exporting. Give concurrent
shards of one cell the same unique run ID; use a new ID for every round, mode,
route, concurrency, server and topology. Use a fresh directory per campaign and
unique output names. A failed client produces no new result; never reuse stale files.

Schema 1 stores request configuration, client hostname, unique sample ID,
requested/completed counts, body bytes, monotonic start/end nanoseconds and raw
latency nanoseconds. Export happens after the timed load and channel cleanup;
throughput-only mode exports an empty latency array. Existing request bytes and
latency semantics are unchanged: the first response per connection counts toward
RPS/body bytes but is excluded from latency. Export and offline pooling consume
additional client memory; exclude that memory from server RSS and allow headroom.

```sh
swift build -c release --product whitethroated-benchmark-merge
.build/release/whitethroated-benchmark-merge 8 /tmp/campaign/round-1-shard-*.json \
  > /tmp/campaign/round-1-pooled.json
```

The first argument is the expected shard count, so a missing shard fails rather
than silently reducing load. The merger rejects duplicate samples, different run
IDs/configurations/client hosts, incomplete request counts, inconsistent latency
counts, invalid timing and nonoverlapping measurement intervals. Ports may differ
for explicit sharding. All shards must run on the **same client host in the same
boot**; hostname/overlap checks cannot prove this, so retain host/boot metadata.
It cannot verify response body/header parity or that declared topology actually ran;
verify those separately before load. It does not provide request timeouts.

Pooled percentiles use the client's existing floor((N−1)×p) order statistic on all
samples, rather than an average of shard percentiles. Aggregate RPS divides total
completed requests by earliest start to latest finish, including launch skew;
it is not the sum of shard-local RPS. Report launch skew and shard durations from
raw files, keep the same shard apparatus across comparisons, and reject excessive
skew. Do not mix the new wall-window RPS or pooled tails with historic summed-RPS /
mean-of-shard-percentile tables. Rebaseline all compared cases. Schema 1 successful
files imply zero observed failures; absent/failed shards invalidate the cell, not
zero errors. Preserve stderr and exit status as well as JSON.

This tooling adds no production runtime path and makes no new speed claim.

Pooled topology follow-up (macOS, `GET /`, c256, three interleaved rounds,
8 one-thread client shards, 1M requests/cell; see
`docs/benchmark-pooled-topology-2026-10-17.md`): all 24 cells completed, but
large round variance prevents accepting a Pareto improvement (verdict C).
Median 4×2 versus 1×8 shows nominal RPS +3.1%, p90 −5.1%, p99 −25.1%
with **p50 +24.5%**; every multi-process topology misses the p50 gate in
every paired round. New pooled quantiles and wall-window RPS must not be
mixed with earlier shard-average/summed-RPS tables or different client thread
counts. No new deployment recommendation or production optimization follows.

## Swift-native topology campaign

`whitethroated-benchmark-campaign` replaces manual orchestration for the next
1×8 versus 4×2 adjudication. It never builds during measurement. First run the
release tests and build the server, client, merger and campaign products:

```sh
swift test -c release
swift build -c release --product whitethroated-benchmark-server
swift build -c release --product whitethroated-benchmark-client
swift build -c release --product whitethroated-benchmark-merge
swift build -c release --product whitethroated-benchmark-campaign
ulimit -n 10240
WHITETHROATED_CAMPAIGN_OUTPUT=/tmp/topology-unique \
  .build/release/whitethroated-benchmark-campaign
```

The output directory must be absolute and not already exist. Default plan:
5 alternating rounds of 1×8 / 4×2, `GET /`, `GET /user/42`, `POST /user`,
c64/c256/c512, 8 one-thread client shards, 125000 requests per shard. Each
worker receives 10000 warmup requests per route. A full campaign has 270 cells:
throughput-only, latency-enabled and separate resource-observation modes for
every combination. Resource mode uses the throughput-only client and samples
worker `ps` RSS/cumulative CPU about every 250 ms; its RPS is diagnostic only.
The primary throughput and latency cells run without that sampler. Sampling and
client export overhead are not calibrated away.

Other settings (all optional):

| Environment variable | Meaning |
|---|---|
| `WHITETHROATED_CAMPAIGN_ROOT` | Repository path; defaults to current directory |
| `WHITETHROATED_CAMPAIGN_SERVER` | `whitethroated-benchmark-server` (default), `whitethroated-runtime-benchmark-server`, `raw-nio-benchmark-server`, or `custom-http1-benchmark-server` |
| `WHITETHROATED_CAMPAIGN_PORT` | First of four loopback ports, default 3310 |
| `WHITETHROATED_CAMPAIGN_HTTP1_EXPERIMENT=1` | Opt-in five-route raw-NIO vs custom-HTTP/1 matrix; adds `/prepared` and `/json` without changing the historical default campaign |
| `WHITETHROATED_CAMPAIGN_SMOKE=1` | Correctness-only run: one round, c64, 8000 requests/shard; bypasses quiet-host rejection and marks completion as smoke |

Worker/client launch environments remove inherited `WHITETHROATED_*` settings,
then set the exact cell configuration. Optional middleware/upload/etc. flags
cannot silently contaminate the matrix. Other runtime interposition/profiling
environment settings remain the operator's responsibility; use a clean terminal.
The server must already be built in release mode. Keep the toolchain/build flags
with the campaign archive; binary location alone cannot prove how it was built.

The runner checks that the required ports are free with temporary loopback binds
before starting workers. It waits up to 30 seconds for connection readiness,
retrying only connection-refused startup failures; bad HTTP responses and
response timeouts fail immediately. It verifies status, exact body,
Content-Length and relevant Content-Type on every worker/route before load.
The campaign stops on HTTP mismatch, child
failure, 120-second cell timeout, HEAD change or a quiet-host gate failure.
SIGINT/SIGTERM request cleanup: it terminates/reaps its own clients/workers and
uses SIGKILL only for its own children still alive after two seconds. Do not
SIGKILL the runner if graceful cleanup is needed. Reserve the port range for the
campaign and inspect worker failures/logs before interpreting results.

Initial quiet-host admission requires 1- and 5-minute load averages no greater
than half the available logical cores, normal macOS memory pressure (level 1),
and summed unrelated-process `ps %CPU` no greater than 100% (one core). On Linux
the memory proxy is MemAvailable >=10% of MemTotal; compatibility/performance
validation remains pending. Between cells, memory and unrelated-process CPU gates
remain active, but load-average rejection is disabled because it includes the
campaign's own preceding load. `ps %CPU` is a platform-smoothed estimate, not an
instantaneous isolation guarantee. These are conservative admission rules,
not proof of a noiseless machine; inspect round spread before any claim.

Each campaign preserves its configuration/plan, commit, worktree diff, Swift
version, kernel, dependency lockfile, pre/post host observations, HTTP verification
outputs, worker/client logs, raw samples and pooled summaries. A resource cell
also saves raw per-worker observations and a resource summary:

- Initial/post RSS and maximum sampled **concurrent aggregate** RSS (KiB).
- Summed worker CPU-time delta and observation-envelope wall time.
- CPU utilization and completed requests per worker CPU second.

The CPU envelope brackets client startup, load and client export/cleanup; it is
not a pure service-time counter. `ps` CPU time has limited resolution. Sampled
RSS can miss between-sample peaks and is not process-lifetime high-water RSS.
Ready worker observations are recorded after HTTP verification and before warmup.
Keep resource cells separate
from latency/throughput cells when reporting these limitations. Derive memory
per connection using the cell concurrency with idle baseline shown. The runner
does not collect hardware counters, context switches or CPU migrations.

`COMPLETE.txt` means execution completed, not that acceptance gates passed.
`ABORTED.txt` preserves the failure; partial results must not be presented as a
complete matrix. Do not resume into the same directory or silently drop outliers.
Raw JSON files can be large; archive/compress externally after all children exit.
No binary/source changes or other tests/builds should run during a campaign.

Campaign readiness follow-up: the five-round attempt at 17:27 Asia/Jakarta on
2026-10-17 failed initial admission because macOS memory-pressure level was 2
(warning), despite passing CPU/load checks. Zero performance cells started;
see `docs/benchmark-campaign-readiness-2026-10-17.md` and its raw preflight JSON.
The gate remained enabled. Harness smoke results are not comparative evidence.

Run the opt-in campaign lifecycle regressions after building the campaign product:

```sh
WHITETHROATED_CAMPAIGN_INTEGRATION=1 swift test -c release --filter CampaignLifecycleTests
```

They require loopback access and unused test ports 3470/3480/3490. Normal test runs
skip these three subprocess tests; an explicitly enabled full release run executes
them along with the suite. They verify correctness and cleanup, never timing wins.
