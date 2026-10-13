# Hudhud benchmarks

Performance is a product requirement, not a marketing claim.

Hudhud should be compared with other frameworks only using reproducible release builds on the same machine, operating system, HTTP protocol, connection settings, payload, and benchmark tool.

## Network benchmark harness

Hudhud ships with a dedicated benchmark server and a small `wrk` runner.

Available benchmark routes:

- `/plaintext` — static text response.
- `/json` — static JSON response.
- `/users/:id` — one dynamic route parameter.
- `/users/:id/posts/:post` — two dynamic route parameters.

Run the default benchmark:

```bash
./Benchmarks/run.sh
```

Override the workload with environment variables:

```bash
ROUTE=/users/42 \
THREADS=8 \
CONNECTIONS=256 \
DURATION=60s \
./Benchmarks/run.sh
```

The runner always builds the benchmark server with `-c release`.

## Manual benchmark

Build and run the benchmark server:

```bash
swift build -c release --product hudhud-benchmark-server
.build/release/hudhud-benchmark-server
```

Then run:

```bash
wrk -t4 -c128 -d30s --latency \
  http://127.0.0.1:3000/plaintext
```

## Comparison protocol

When comparing Hudhud with Actix Web, Vapor, Hummingbird, raw SwiftNIO, or another server:

1. Use the same physical machine.
2. Pin all servers to release/optimized builds.
3. Use the same response bytes and content type.
4. Use the same HTTP version.
5. Use the same keep-alive behavior.
6. Use the same `wrk` threads, connections, and duration.
7. Warm each server before collecting results.
8. Run multiple samples instead of trusting one run.
9. Record CPU and resident memory alongside throughput.
10. Compare tail latency, not only requests per second.

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
- Operating system.
- CPU model.

## Current optimization state

Completed:

- Method-aware trie routing.
- UTF-8 static route matching.
- Static-route priority with parameter fallback.
- Compiled middleware chain.
- Direct `ByteBuffer` response support.
- Lazy route parameter decoding.
- URI-backed routing without allocating a separate path `String` on the router hot path.
- HTTP pipelining assistance.

Next measurements:

1. Quantify route matching cost by route depth.
2. Measure ARC retain/release traffic.
3. Measure the cost of `EventLoopFuture` creation for synchronous handlers.
4. Compare text responses with prebuilt `ByteBuffer` responses.
5. Measure middleware cost per layer.
6. Profile request-body accumulation.
7. Evaluate a synchronous internal responder fast path.
8. Compare Hudhud against a minimal raw SwiftNIO server before comparing against Actix Web.

No performance number should be published until the benchmark environment and commands are recorded with it.
