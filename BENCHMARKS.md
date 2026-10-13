# Hudhud benchmarks

Performance is a product requirement, not a marketing claim.

Hudhud should be compared against other frameworks only with reproducible release builds on the same machine, operating system, HTTP protocol, connection settings, payload, and benchmark tool.

## Initial smoke benchmark

Build the example server:

```bash
swift build -c release
.build/release/hudhud-example
```

Then benchmark the root route from another terminal:

```bash
wrk -t4 -c128 -d30s http://127.0.0.1:3000/
```

Record at minimum:

- Requests per second
- Average latency
- p50 latency
- p99 latency
- Transfer rate
- CPU utilization
- Resident memory
- Swift version
- Operating system
- CPU model

## Performance roadmap

1. Replace linear route scanning with a method-aware radix tree.
2. Avoid intermediate `String` allocations during route matching.
3. Add direct `ByteBuffer` response bodies.
4. Benchmark middleware dispatch overhead.
5. Add pipelining correctness tests.
6. Measure allocator pressure and ARC traffic.
7. Tune NIO channel options from benchmark evidence.
8. Add Linux CI benchmarks with pinned hardware where practical.
9. Compare against Vapor, Hummingbird, Actix Web, and a minimal raw NIO server.
10. Never optimize from requests-per-second alone; track tail latency and memory too.
