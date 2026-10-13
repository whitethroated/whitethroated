# Hudhud benchmarks

Performance is a product requirement, not a marketing claim.

Hudhud should be compared with other frameworks only using reproducible release builds on the same physical machine, operating system, HTTP protocol, connection settings, payload, and benchmark tool.

## Pinned benchmark baseline

The repository intentionally pins the runtime baseline:

- Swift development/benchmark toolchain: 6.4.0.
- Swift Package Manager tools version: 6.1.
- SwiftNIO: exactly 2.104.0.

Do not publish benchmark numbers from a dependency graph that differs from the recorded baseline without documenting the difference.

## Benchmark servers

The repository contains two release benchmark servers.

### Hudhud server

Routes:

- `/prepared` — prepared immutable plaintext response.
- `/plaintext` — ordinary synchronous plaintext handler.
- `/json` — ordinary synchronous JSON handler.
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

### Raw SwiftNIO control

`raw-nio-benchmark-server` serves the same `Hello, World!` bytes and content type as Hudhud's `/prepared` route.

For the common HTTP/1.1 keep-alive path, both servers precompute their response body and response head. Both use SwiftNIO's HTTP server pipeline with pipelining assistance enabled.

Run the paired comparison:

```bash
./Benchmarks/compare.sh
```

The script builds both servers in release mode and runs them sequentially with identical `wrk` settings on the same host and port.

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
- Lazy route parameter decoding from byte ranges.
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

Next measurements and optimizations:

1. Quantify Hudhud overhead relative to the raw NIO control.
2. Measure ordinary synchronous `/plaintext` against prepared `/prepared`.
3. Quantify fast and asynchronous middleware overhead per layer.
4. Combine route segment scanning and hashing where profiling validates the gain.
5. Measure route matching by static/dynamic depth and route count.
6. Profile ARC retain/release traffic.
7. Profile request-body accumulation.
8. Evaluate response write batching from profiler evidence.
9. Compare with Actix Web only after the raw-NIO framework overhead is understood.

No performance number should be published until the benchmark environment and commands are recorded with it.
