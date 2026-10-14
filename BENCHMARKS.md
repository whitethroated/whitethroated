# Hudhud benchmarks

Performance is a product requirement, not a marketing claim.

Hudhud should be compared with other frameworks only using reproducible release builds on the same physical machine, operating system, HTTP protocol, connection settings, payload, and benchmark tool.

## Pinned benchmark baseline

The repository intentionally pins the runtime baseline:

- Swift development/benchmark toolchain: 6.4.0.
- Swift Package Manager tools version: 6.1.
- SwiftNIO: exactly 2.104.0.
- Rust control toolchain: 1.99.0.
- Actix Web control: exactly 4.16.0.

Do not publish benchmark numbers from a dependency graph that differs from the recorded baseline without documenting the difference.

## Tooling sanity check

Before running performance tests, validate shell syntax and the benchmark summarizer:

```bash
./Benchmarks/check.sh
```

This check does not start a server and does not require network access.

## In-process core dispatch benchmark

Network benchmarks are the final performance signal, but small router/responder changes can be hidden by kernel and socket noise. Run the release-mode core dispatch benchmark:

```bash
./Benchmarks/core.sh
```

Increase the iteration count when comparing small changes:

```bash
ITERATIONS=5000000 ./Benchmarks/core.sh
```

The benchmark exercises the transport dispatch path without opening a socket:

- prepared canonical static route through the exact full-path table.
- the same prepared route with a trailing slash, forcing trie fallback.
- synchronous static route.
- synchronous single-parameter route with parameter decoding.
- synchronous targeted-query route with query decoding.
- synchronous static route that explicitly reads `request.method`, isolating the lazy method-conversion cost.

The test is skipped during normal `swift test` runs unless `HUDHUD_CORE_BENCHMARK=1` is set.

To isolate dispatch plus the `HTTPServerHandler` outbound writer using `EmbeddedChannel`:

```bash
./Benchmarks/writer-core.sh
```

Increase its iterations independently:

```bash
ITERATIONS=500000 ./Benchmarks/writer-core.sh
```

The writer benchmark compares prepared and ordinary synchronous text responses while draining the same three HTTP response parts (`head`, `body`, `end`) per request. Compare it with `core.sh` to determine whether a measured delta comes primarily from dispatch or response writing.

Treat all in-process numbers as diagnostic ns/op measurements, not as substitutes for the repeated `wrk` network suite.

## Benchmark servers

The repository contains two release benchmark servers.

### Hudhud server

Core routes registered in the default benchmark server:

- `/prepared` — prepared immutable plaintext response.
- `/plaintext` — ordinary synchronous plaintext handler.
- `/json` — ordinary synchronous JSON handler.
- `/concurrent` — Swift async/await handler, isolating per-request Task bridge overhead.
- `/users/:id` — one dynamic route parameter.
- `/users/:id/posts/:post` — two dynamic route parameters.

Feature-specific benchmark routes are registered only by their dedicated runners so they do not contaminate the core route table:

- request streaming: `HUDHUD_UPLOAD_BENCHMARKS=1`.
- response streaming: `HUDHUD_RESPONSE_STREAM_BENCHMARKS=1`.
- router stress matrix: `HUDHUD_ROUTER_BENCHMARKS=1`.
- multipart parser: `HUDHUD_MULTIPART_BENCHMARKS=1`.

The prepared route precomputes:

- Body bytes.
- `Content-Length`.
- HTTP/1.1 response head.

The route stores immutable prepared-response storage directly, and the internal router/responder pipeline carries that storage reference without rebuilding the public wrapper. It is the closest Hudhud control path to raw SwiftNIO.

Run the default Hudhud benchmark:

```bash
./Benchmarks/run.sh
```

Override the workload:

```bash
ROUTE=/users/42 \
THREADS=8 \
CONNECTIONS=256 \
DURATION=60s \
./Benchmarks/run.sh
```

Measure pass-through middleware layers:

```bash
FAST_MIDDLEWARE_LAYERS=4 \
ROUTE=/plaintext \
./Benchmarks/run.sh
```

For asynchronous middleware:

```bash
ASYNC_MIDDLEWARE_LAYERS=4 \
ROUTE=/plaintext \
./Benchmarks/run.sh
```

Run the middleware scaling matrix:

```bash
./Benchmarks/middleware.sh
```

The matrix compares 0, 1, 4, and 8 pass-through layers for both the synchronous `useFast` path and the regular future-based middleware path.

### Response-stream benchmark

Run the response writer matrix:

```bash
./Benchmarks/response-stream.sh
```

It compares the same 13-byte logical payload across:

1. Ordinary synchronous plaintext.
2. Two streamed body parts with explicit `Content-Length: 13`.
3. Two streamed body parts with HTTP/1.1 chunked framing.
4. Chunked streaming with an intermediate flush.

This separates multi-part response machinery from chunked framing and explicit flush cost. The intermediate-flush case is intentionally expected to trade throughput for lower delivery latency.

These routes are registered only when `HUDHUD_RESPONSE_STREAM_BENCHMARKS=1`; the runner sets it automatically so the normal prepared/raw-NIO/Actix baseline does not inherit extra GET route fan-out from this benchmark.

### Request-body benchmark

Hudhud keeps ordinary request aggregation and streaming as separate route types. Compare the same POST payload against both paths:

```bash
./Benchmarks/upload.sh
```

The default matrix runs each 1 KiB and 64 KiB payload through:

- ordinary aggregated body handling.
- streamed body with the synchronous chunk consumer.
- streamed body with a future-returning chunk consumer.

All routes return the same small text response and discard payload contents after accounting. The synchronous streaming case isolates direct chunk dispatch. The future case returns the event loop's cached succeeded `Void` future for every chunk, so its delta primarily exposes future/backpressure state-machine overhead rather than application I/O latency.

The upload routes are registered only when `HUDHUD_UPLOAD_BENCHMARKS=1`. The upload runner sets this automatically so request-streaming feature detection does not contaminate the normal plaintext/raw-NIO/Actix baseline.

Override load settings as usual:

```bash
WORKERS=8 \
THREADS=8 \
CONNECTIONS=128 \
DURATION=30s \
./Benchmarks/upload.sh
```

This benchmark is primarily useful together with process RSS/allocation profiling. Streaming can intentionally trade some per-chunk dispatch overhead for bounded request-body memory.

For an isolated peak-RSS comparison, restart the server for each route:

```bash
./Benchmarks/upload-memory.sh
```

The default memory workload sends 1 MiB bodies with 64 concurrent connections and reports baseline RSS, peak RSS, and RSS growth for the aggregated and streaming routes separately. Override load settings when needed:

```bash
CONNECTIONS=128 \
DURATION=30s \
BYTES=1048576 \
./Benchmarks/upload-memory.sh
```

The aggregated benchmark route uses the default 1 MiB application body limit, so this runner intentionally caps `BYTES` at 1,048,576.

### Multipart parsing benchmark

Measure multipart parser overhead independently from request streaming:

```bash
./Benchmarks/multipart.sh
```

For each 1 KiB, 64 KiB, and 1 MiB file payload, the runner sends the **same multipart/form-data wire body** to:

1. `/upload-stream` — raw synchronous streaming control that discards chunks.
2. `/upload-multipart` — the streaming multipart parser using the throwing-synchronous chunk path, with emitted events discarded.

Because both cases receive identical multipart headers, boundaries, body bytes, worker count, connection count, and HTTP settings—and neither allocates a future for successful chunks—most of the delta isolates multipart parsing/state-machine cost.

Override the load when profiling:

```bash
WORKERS=8 \
THREADS=8 \
CONNECTIONS=64 \
DURATION=30s \
./Benchmarks/multipart.sh
```

Multipart benchmark routes are registered only when `HUDHUD_MULTIPART_BENCHMARKS=1`; the runner sets the flag automatically.

For peak-RSS comparison, restart the process between the raw-stream and multipart-parser cases:

```bash
./Benchmarks/multipart-memory.sh
```

The default workload uses a 4 MiB file payload with 32 concurrent connections. Both cases receive the same multipart wire bytes, so the reported RSS growth helps distinguish parser staging from the base request-streaming transport cost.

Override the workload when needed:

```bash
BYTES=7340032 \
CONNECTIONS=16 \
DURATION=30s \
./Benchmarks/multipart-memory.sh
```

The file payload is capped below the benchmark route's 8 MiB total request limit to leave room for multipart framing bytes.

### Router scaling benchmark

The benchmark server also registers dedicated route shapes for measuring router scaling.

The matrix begins with:

- `/prepared` — canonical exact-static lookup.
- `/prepared/` — the same route resolved through trie fallback because of the trailing slash.

Static trie depth is then measured with trailing-slash requests so the exact-static table intentionally misses:

- 1 segment after the prefix.
- 4 segments.
- 8 segments.
- 16 segments.

Static trie fan-out is measured the same way:

- 16 sibling routes.
- 256 sibling routes.
- 4,096 sibling routes.

Dynamic parameter capture:

- 1 parameter, with name and range stored inline.
- 2 parameters, with both names and ranges stored inline.
- 4 parameters, which exercises promotion beyond inline name/range storage.

Run the full router matrix with an explicit server worker count:

```bash
WORKERS=4 ./Benchmarks/router.sh
```

The matrix runs against one warmed release server so machine and process setup remain constant across the route cases. Static depth and fan-out are each measured twice: canonical paths hit the exact full-path table, while a trailing slash intentionally misses the exact table and exercises trie fallback semantics.

The matrix also registers the same single-parameter route for GET and PUT. GET shares a method table containing thousands of exact static benchmark routes; PUT has no exact static entry. Their delta isolates the cost of an exact-table miss before dynamic trie lookup.

Router-matrix routes are registered only when `HUDHUD_ROUTER_BENCHMARKS=1`; `router.sh` sets it automatically. The normal prepared/raw-NIO/Actix baseline therefore does not inherit the router stress-test route table.

Interpret exact-static cost by comparing `/prepared` with `/prepared/`. Interpret trie depth/fan-out using the trailing-slash cases. The response endpoint is intentionally the same prepared response, so most of the delta should come from route lookup rather than serialization.

### Wire contract verification

Before collecting cross-runtime numbers, verify the HTTP/1.1 response contract:

```bash
./Benchmarks/verify-wire.sh
```

The verifier builds and runs Hudhud, raw SwiftNIO, and Actix sequentially and confirms that all three return the same plaintext body plus the same `Content-Type`, `Content-Length`, and fixed `Date` value.

### Actix Web control

The repository includes an Actix Web control pinned to `actix-web = 4.16.0` with compression and HTTP/2 features disabled for the plaintext HTTP/1.1 comparison.

Actix HTTP/1.1 normally inserts a generated `Date` header when one is absent. The benchmark explicitly supplies the same fixed `Date` value to Hudhud, raw SwiftNIO, and Actix. This suppresses Actix's automatic date generation and keeps the response header set materially closer across implementations.

Run:

```bash
./Benchmarks/compare-actix.sh
```

The comparison runs sequentially on the same host and port:

1. Hudhud `/prepared`.
2. Hudhud ordinary synchronous `/plaintext`.
3. Actix Web `/plaintext`.

Use `WORKERS` to force the same SwiftNIO event-loop count and Actix worker count:

```bash
WORKERS=8 \
THREADS=8 \
CONNECTIONS=256 \
DURATION=60s \
./Benchmarks/compare-actix.sh
```

This is intentionally not a claim that prepared Hudhud and idiomatic Actix perform identical work internally. The ordinary Hudhud synchronous route is included as the closer framework-level comparison, while the prepared route measures Hudhud's optimized immutable-response ceiling.

### Raw SwiftNIO control

`raw-nio-benchmark-server` serves the same `Hello, World!` bytes and content type as Hudhud's `/prepared` route.

For the common HTTP/1.1 keep-alive path, both servers precompute their response body and response head. Both use SwiftNIO's HTTP server pipeline with pipelining assistance enabled.

The raw NIO and Hudhud controls include the same fixed RFC-style `Date` header used by the Actix comparison.

Run the paired comparison:

```bash
./Benchmarks/compare.sh
```

The script builds both servers in release mode and runs them sequentially with identical `wrk` settings on the same host and port.

## Repeated benchmark suite

Do not use one run as a performance conclusion. The suite runner records multiple raw samples together with machine and compiler metadata.

Raw SwiftNIO comparison:

```bash
MODE=raw-nio \
SAMPLES=5 \
WORKERS=8 \
THREADS=8 \
CONNECTIONS=256 \
DURATION=30s \
./Benchmarks/suite.sh
```

Actix Web comparison:

```bash
MODE=actix \
SAMPLES=5 \
WORKERS=8 \
THREADS=8 \
CONNECTIONS=256 \
DURATION=30s \
./Benchmarks/suite.sh
```

Each run is written beneath `benchmark-results/<timestamp>-<mode>/` together with `environment.txt`. Generated benchmark records are ignored by Git by default so experimental runs are not accidentally published.

At the end of the suite, `Benchmarks/summarize.py` parses all raw `wrk` samples and writes:

- `summary.md` — human-readable median throughput and latency table.
- `summary.json` — raw parsed measurements plus machine-readable summaries.

The summary reports median requests/sec, min/max requests/sec, and median p50/p90/p99 latency across samples.

You can rerun the summarizer independently:

```bash
python3 Benchmarks/summarize.py \
  benchmark-results/<result-directory>
```

Always preserve the raw sample files used to produce a published summary.

## Linux CPU and ARC profiling

On Linux, use `perf stat` to capture hardware/runtime counters while applying the same `wrk` load:

```bash
ROUTE=/plaintext \
WORKERS=8 \
THREADS=8 \
CONNECTIONS=256 \
DURATION=20s \
PROFILE_MODE=stat \
./Benchmarks/profile-linux.sh
```

The stat mode records:

- task clock.
- CPU cycles.
- instructions.
- branches and branch misses.
- cache references and misses.
- context switches.
- CPU migrations.
- page faults.

For sampled call stacks:

```bash
ROUTE=/plaintext \
PROFILE_MODE=record \
./Benchmarks/profile-linux.sh
```

Record mode writes `perf.data`, a text `perf-report.txt`, and an `arc-symbols.txt` extraction for Swift retain/release symbols when they are visible in the profile.

Run the profiler separately for at least:

```text
/prepared
/plaintext
/concurrent
/users/42
```

Do not run `perf stat` and `perf record` simultaneously when collecting publishable numbers. Profiling changes the workload and should be used to explain benchmark deltas, not as the throughput result itself.

Linux kernel perf permissions may require adjusting `kernel.perf_event_paranoid` or using an environment where hardware counters are available.

## Comparison protocol

When comparing Hudhud with raw SwiftNIO, Hummingbird, Vapor, Actix Web, or another server:

1. Use the same physical machine.
2. Pin all servers to release/optimized builds.
3. Record exact compiler and dependency versions.
4. Use the same response bytes and content type.
5. Use the same HTTP version.
6. Use the same keep-alive behavior.
7. Use the same benchmark threads, connections, and duration.
8. Warm each server before collecting results.
9. Run multiple samples instead of trusting one run.
10. Record CPU and resident memory alongside throughput.
11. Compare tail latency, not only requests per second.
12. Compare Hudhud with minimal raw SwiftNIO before attributing a delta to Swift itself.
13. Do not tune only one side of a comparison.

Record at minimum:

- Requests per second.
- Average latency.
- p50 latency.
- p90 latency.
- p99 latency.
- Transfer rate.
- CPU utilization.
- Resident memory.
- Swift/Rust version.
- SwiftNIO/framework version.
- Operating system.
- CPU model.
- Benchmark command.
- Commit SHA.

## Current optimization state

Completed:

- Custom open-addressed exact full-path static route table with trie fallback.
- Open-addressed trie static-child tables keyed directly by segment FNV hashes.
- Direct roots for common HTTP methods.
- Method-aware UTF-8 trie routing.
- Static-route priority with parameter fallback.
- Direct routing over URI bytes.
- Route segment boundary scanning and hashing in one byte pass.
- Lazy route parameter decoding from byte ranges.
- Inline route-parameter range storage for the first two parameters.
- Lazy query parsing.
- Custom percent decoding without Foundation URL parsing.
- Compiled asynchronous middleware chain.
- Synchronous middleware fast path.
- Synchronous responder fast path.
- Direct `ByteBuffer` response support.
- Prepared immutable response path.
- Prepared routes stored directly in the routing trie.
- Prepared body and content-length precomputation.
- Prepared HTTP/1.1 response-head precomputation.
- Bodyless-request empty-buffer reuse.
- First-body-chunk reuse instead of unconditional copying.
- Configurable request-body limits.
- HTTP pipelining assistance.
- Express-style `HEAD` fallback to `GET`.
- HTTP/1.1 keep-alive without a redundant `Connection: keep-alive` response header.
- Raw SwiftNIO control server with equivalent prepared response behavior.
- Exact SwiftNIO dependency pin.
- Router depth and fan-out benchmark matrix.

Next measurements and optimizations:

1. Quantify Hudhud overhead relative to the raw NIO control.
2. Measure ordinary synchronous `/plaintext` against prepared `/prepared`.
3. Measure async/await `/concurrent` against synchronous `/plaintext` to quantify Task bridge cost.
4. Run `Benchmarks/response-stream.sh` to separate multi-part writes, chunked framing, and flush overhead.
5. Run the router matrix and quantify depth/fan-out cost.
4. Quantify fast and asynchronous middleware overhead per layer.
5. Profile ARC retain/release traffic.
6. Profile request-body accumulation.
7. Evaluate response write batching from profiler evidence.
8. Run the pinned Actix Web comparison after the raw-NIO framework overhead is understood.

No performance number should be published until the benchmark environment and commands are recorded with it.
