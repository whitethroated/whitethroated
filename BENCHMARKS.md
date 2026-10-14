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

- prepared static route.
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

## Request-body streaming measurements

Streaming performance should be measured separately from tiny plaintext response throughput.

For upload benchmarks, record at least:

- request body size.
- chunk count when known.
- requests/sec.
- p50/p99 latency.
- CPU utilization.
- peak RSS.
- total allocated bytes when tooling is available.

Compare a streaming endpoint against an otherwise equivalent aggregated-body endpoint. Use payload sizes large enough for body-copy and RSS behavior to dominate routing noise.

Do not claim a streaming win from requests/sec alone; the primary expected benefit is bounded memory growth and explicit backpressure under slow consumers.

Run the paired upload benchmark:

```bash
UPLOAD_BYTES=65536 \
WORKERS=4 \
THREADS=4 \
CONNECTIONS=64 \
DURATION=20s \
./Benchmarks/streaming.sh
```

The benchmark sends the same generated binary request body to:

- `/aggregate-upload` — ordinary Hudhud body aggregation.
- `/stream-upload` — synchronous chunk streaming with no per-chunk future.

Repeat with larger payloads, for example `UPLOAD_BYTES=1048576` and `UPLOAD_BYTES=8388608`.

On Linux, `streaming.sh` samples `/proc/<pid>/status` during each isolated server run and prints `peak_rss_kib`. On other platforms, collect peak RSS with the platform's native process profiler.

## Benchmark servers

The repository contains two release benchmark servers.

### Hudhud server

Core routes:

- `/prepared` — prepared immutable plaintext response.
- `/plaintext` — ordinary synchronous plaintext handler.
- `/json` — ordinary synchronous JSON handler.
- `/concurrent` — Swift async/await handler, isolating per-request Task bridge overhead.
- `/users/:id` — one dynamic route parameter.
- `/users/:id/posts/:post` — two dynamic route parameters.

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

### Request-body benchmark

Hudhud keeps ordinary request aggregation and streaming as separate route types. Compare the same POST payload against both paths:

```bash
./Benchmarks/upload.sh
```

The default matrix runs:

- 1 KiB aggregated body.
- 1 KiB streamed body.
- 64 KiB aggregated body.
- 64 KiB streamed body.

Both routes return the same small text response. The streaming route discards each chunk immediately, while the ordinary route uses Hudhud's normal body aggregation path.

Override load settings as usual:

```bash
WORKERS=8 \
THREADS=8 \
CONNECTIONS=128 \
DURATION=30s \
./Benchmarks/upload.sh
```

This benchmark is primarily useful together with process RSS/allocation profiling. Streaming can intentionally trade some per-chunk dispatch overhead for bounded request-body memory.

### Router scaling benchmark

The benchmark server also registers dedicated route shapes for measuring router scaling.

Static depth:

- 1 segment after the prefix.
- 4 segments.
- 8 segments.
- 16 segments.

Static fan-out:

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

The matrix runs against one warmed release server so machine and process setup remain constant across the route cases.

Interpret the matrix by comparing each case to `/prepared`. The response path is intentionally the same prepared response for static depth and fan-out cases, so most of the delta should come from routing.

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
4. Run the router matrix and quantify depth/fan-out cost.
4. Quantify fast and asynchronous middleware overhead per layer.
5. Profile ARC retain/release traffic.
6. Profile request-body accumulation.
7. Evaluate response write batching from profiler evidence.
8. Run the pinned Actix Web comparison after the raw-NIO framework overhead is understood.

No performance number should be published until the benchmark environment and commands are recorded with it.
