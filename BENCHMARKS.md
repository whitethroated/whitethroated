# Hudhud benchmarks

Performance is a product requirement, not a marketing claim.

Hudhud keeps benchmark implementation code in Swift. External load generators and profilers may be used from the command line, but their source is not vendored into this repository.

## Source-language policy

Tracked implementation and benchmark source code in this repository must be Swift.

Allowed non-Swift tracked files are documentation and repository metadata such as Markdown, YAML, TOML configuration that is not application source, and ignore files. Benchmark wrappers written in Shell, Python, Lua, Rust, or another implementation language do not belong in this repository.

Cross-framework controls such as Actix Web must live outside the Hudhud repository. This keeps the framework itself auditable as a Swift-only codebase while still allowing external comparisons.

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
swift build -c release --product hudhud-benchmark-server
swift build -c release --product raw-nio-benchmark-server
```

Do not benchmark a commit that does not pass the release test suite.

## In-process core dispatch benchmark

The diagnostic benchmark is implemented in Swift inside `CoreBenchmarkTests`.

Run core dispatch:

```bash
HUDHUD_CORE_BENCHMARK=1 \
HUDHUD_CORE_ITERATIONS=5000000 \
swift test -c release \
  --filter CoreBenchmarkTests/testCoreDispatchBenchmark
```

It measures:

- prepared exact-static dispatch.
- prepared trie fallback.
- conditional prepared 200 and 304 dispatch.
- synchronous static dispatch.
- dynamic parameter capture.
- targeted query and cookie access.
- not-found dispatch.
- lazy HTTP method conversion.

## Router-only benchmark

```bash
HUDHUD_ROUTER_CORE_BENCHMARK=1 \
HUDHUD_ROUTER_CORE_ITERATIONS=10000000 \
swift test -c release \
  --filter CoreBenchmarkTests/testRouterLookupBenchmark
```

This bypasses transport writes and isolates route lookup behavior, including exact-table hits and misses before trie fallback.

## Transport writer benchmark

```bash
HUDHUD_TRANSPORT_BENCHMARK=1 \
HUDHUD_TRANSPORT_ITERATIONS=500000 \
swift test -c release \
  --filter CoreBenchmarkTests/testTransportWriterBenchmark
```

This compares three transport paths through `EmbeddedChannel`:

- prepared 200 with a cached HTTP/1.1 head and body buffer.
- conditional prepared 304 with a cached normalized bodyless HTTP/1.1 head.
- ordinary synchronous 200, which constructs the response head from the dynamic response.

The prepared 304 case specifically measures the bodyless writer path after setup-time removal of forbidden framing headers.

Treat these in-process measurements as diagnostic ns/op data. They are not substitutes for network measurements.

## Hudhud network benchmark server

Start Hudhud in release mode:

```bash
HUDHUD_HOST=127.0.0.1 \
HUDHUD_PORT=3000 \
HUDHUD_THREADS=4 \
swift run -c release hudhud-benchmark-server
```

Core routes include:

- `/prepared` — prepared immutable plaintext.
- `/plaintext` — ordinary synchronous plaintext.
- `/json` — synchronous JSON.
- `/concurrent` — async/await route.
- `/users/:id` — one dynamic parameter.
- `/users/:id/posts/:post` — two dynamic parameters.
- `/conditional-prepared` — conditional prepared ETag path.

Use an external load generator from another terminal. For example:

```bash
wrk -t4 -c128 -d30s --latency \
  http://127.0.0.1:3000/prepared
```

The external tool is intentionally not vendored into this repository.

## Middleware measurements

The benchmark server can compile pass-through middleware layers into the same Swift server:

```bash
HUDHUD_FAST_MIDDLEWARE_LAYERS=4 \
HUDHUD_THREADS=4 \
swift run -c release hudhud-benchmark-server
```

For future-based middleware:

```bash
HUDHUD_ASYNC_MIDDLEWARE_LAYERS=4 \
HUDHUD_THREADS=4 \
swift run -c release hudhud-benchmark-server
```

Measure 0, 1, 4, and 8 layers with identical external load settings.

## Feature-specific benchmark routes

Feature matrices remain implemented in the Swift benchmark server and are opt-in so they do not contaminate the default route table.

Enable request streaming:

```bash
HUDHUD_UPLOAD_BENCHMARKS=1 \
swift run -c release hudhud-benchmark-server
```

Enable response streaming:

```bash
HUDHUD_RESPONSE_STREAM_BENCHMARKS=1 \
swift run -c release hudhud-benchmark-server
```

Enable router stress routes:

```bash
HUDHUD_ROUTER_BENCHMARKS=1 \
swift run -c release hudhud-benchmark-server
```

Enable multipart routes:

```bash
HUDHUD_MULTIPART_BENCHMARKS=1 \
swift run -c release hudhud-benchmark-server
```

Enable the larger conditional-response matrix:

```bash
HUDHUD_CONDITIONAL_BENCHMARKS=1 \
swift run -c release hudhud-benchmark-server
```

Payload generation and network orchestration for these cases should be performed by an external benchmark harness so Hudhud remains Swift-only.

## Raw SwiftNIO control

Start the minimal SwiftNIO control with the same worker count:

```bash
HUDHUD_HOST=127.0.0.1 \
HUDHUD_PORT=3000 \
HUDHUD_THREADS=4 \
swift run -c release raw-nio-benchmark-server
```

The control serves `/plaintext` with the same `Hello, World!` payload, content type, content length, fixed Date header, HTTP/1.1 pipeline, and pipelining assistance used by Hudhud's prepared baseline.

Use the same host, worker count, load-generator threads, connections, duration, warm-up, and HTTP version for both runs.

## Actix Web comparison

Actix is an external control and is intentionally not implemented or vendored in this repository.

When comparing against Actix:

1. Pin the Rust and Actix versions in the benchmark record.
2. Match the response body and relevant headers.
3. Disable unrelated features such as compression and HTTP/2 when comparing the HTTP/1.1 plaintext path.
4. Use the same physical machine and load settings.
5. Run Hudhud-to-raw-SwiftNIO first so Swift framework overhead is understood before interpreting Swift-vs-Rust results.

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
10. Compare p50, p90, and p99 latency in addition to requests per second.
11. Compare Hudhud against raw SwiftNIO before attributing a delta to Swift.
12. Do not tune only one side.

Record at minimum:

- requests per second.
- average latency.
- p50 latency.
- p90 latency.
- p99 latency.
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

1. Raw SwiftNIO versus Hudhud `/prepared`.
2. Hudhud `/prepared` versus `/plaintext`.
3. `/plaintext` versus `/concurrent` to quantify Task-bridge cost.
4. Router-only exact-hit and exact-miss diagnostics.
5. Fast and future-based middleware scaling.
6. Response-stream known-length, chunked, and flush-heavy paths.
7. Aggregated versus streaming request-body throughput and memory.
8. Multipart parser overhead over the raw streaming path.
9. ARC/allocation profiling for unexplained deltas.
10. External Actix comparison after the Swift-side overhead is understood.

No performance number should be published without its environment, command, raw samples, and commit SHA.
