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

- `/prepared` — prepared immutable plaintext response; no handler closure or text-to-buffer conversion per request.
- `/plaintext` — ordinary synchronous plaintext handler.
- `/json` — ordinary synchronous JSON handler.
- `/users/:id` — one dynamic route parameter.
- `/users/:id/posts/:post` — two dynamic route parameters.

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

### Raw SwiftNIO control

`raw-nio-benchmark-server` is deliberately tiny and serves the same `Hello, World!` plaintext bytes, content type, HTTP/1.1 keep-alive behavior, and SwiftNIO HTTP pipeline as the Hudhud prepared-response benchmark.

Its purpose is to measure Hudhud's framework overhead before comparing Swift with another language runtime.

Run the paired comparison:

```bash
./Benchmarks/compare.sh
```

The script builds both servers in release mode and runs them sequentially with identical `wrk` settings on the same host and port.

## Manual benchmark

Build the servers:

```bash
swift build -c release --product hudhud-benchmark-server
swift build -c release --product raw-nio-benchmark-server
```

Run Hudhud:

```bash
.build/release/hudhud-benchmark-server
```

Then:

```bash
wrk -t4 -c128 -d30s --latency \
  http://127.0.0.1:3000/prepared
```

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

- Method-aware trie routing.
- UTF-8 static route matching.
- Static-route priority with parameter fallback.
- Direct routing over URI bytes.
- Lazy route parameter decoding from byte ranges.
- Lazy query parsing.
- Custom percent decoding without Foundation URL parsing.
- Compiled middleware chain.
- Synchronous responder fast path.
- Direct `ByteBuffer` response support.
- Prepared immutable response path.
- Prepared routes stored directly in the routing trie.
- Content-length precomputation for prepared responses.
- First-body-chunk reuse instead of always copying into a new buffer.
- Configurable request-body limits.
- HTTP pipelining assistance.
- Express-style `HEAD` fallback to `GET`.
- HTTP/1.1 keep-alive without a redundant `Connection: keep-alive` response header.
- Dedicated release benchmark runner.
- Raw SwiftNIO control server.
- Exact SwiftNIO dependency pin.

Next measurements and optimizations:

1. Quantify Hudhud overhead relative to the raw NIO control.
2. Measure ordinary synchronous `/plaintext` against prepared `/prepared`.
3. Measure middleware overhead per layer.
4. Measure route matching by static/dynamic depth and route count.
5. Profile ARC retain/release traffic.
6. Profile request-body accumulation.
7. Evaluate a synchronous middleware fast path.
8. Evaluate response-head caching where HTTP semantics permit it.
9. Compare with Actix Web only after the raw-NIO framework overhead is understood.

No performance number should be published until the benchmark environment and commands are recorded with it.
