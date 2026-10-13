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

It is stored directly in the route trie and is the closest Hudhud control path to raw SwiftNIO.

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

Measure one pass-through synchronous middleware layer:

```bash
FAST_MIDDLEWARE=1 \
ROUTE=/prepared \
./Benchmarks/run.sh
```

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

- 1 parameter, stored inline.
- 2 parameters, both stored inline.
- 4 parameters, which exercises promotion beyond the inline range storage.

Run the full router matrix:

```bash
./Benchmarks/router.sh
```

The matrix runs against one warmed release server so machine and process setup remain constant across the route cases.

Interpret the matrix by comparing each case to `/prepared`. The response path is intentionally the same prepared response for static depth and fan-out cases, so most of the delta should come from routing.

### Actix Web control

The repository includes an Actix Web control pinned to `actix-web = 4.16.0` with compression and HTTP/2 features disabled for the plaintext HTTP/1.1 comparison.

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

When reporting results, calculate summary statistics from all samples and preserve the raw records used to produce them.

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
