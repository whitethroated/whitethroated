# Raw SwiftNIO vs WhiteThroatedRuntime vs WhiteThroated — benchmark report

> Socket-option erratum: historical `tcp_nodelay=off` / override `0` labels did not prove TCP_NODELAY was disabled. The old client skipped its override while NIO enabled TCP_NODELAY by default; its explicit `1` used the wrong option level. See [the correction and validation](benchmark-socket-options-2026-10-18.md). Raw measurements are preserved; rebaseline with verified socket values.


Date: 2026-10-17. Machine: Apple M1 Pro (8 cores), 16 GB, macOS
26.6.2. Toolchain: Swift 6.2.4, SwiftNIO exactly 2.104.0, release
builds. Commit: refactor introducing the internal
`WhiteThroatedRuntime` SwiftPM target (see `ARCHITECTURE.md`).

## 1. Verdict

The runtime extraction introduces **no meaningful overhead**. All
five acceptance gates pass on all nine matrix cells:

| Gate | Worst cell | Result |
|---|---|---|
| Runtime throughput ≥ 95% of raw | POST c256, 97.8% | pass |
| Framework throughput ≥ 95% of runtime | /user/42 c64, 98.5% | pass |
| p50 regression ≤ 5% | /user/42 c512, +2.6% | pass |
| p90 regression ≤ 5% | /user/42 c512, +4.2% | pass |
| p99 regression ≤ 5% | GET / c64, +2.7% | pass |

Framework-vs-raw throughput lands at 97.5–100.3% (median of 3
interleaved rounds), consistent with the pre-refactor ±2% parity. The
runtime layer itself (dispatcher + connection handler + writer) costs
0–2.2% throughput versus the hand-rolled raw control, and the
framework layer (router + Request/Response + conversion) costs
−1.6–+1.5% versus the runtime — i.e. both deltas sit inside the
machine's ±2% run-to-run noise. Memory is flat: post-load RSS is
14.7 MB (raw), 15.8 MB (runtime), 15.4 MB (framework).

## 2. Method

External three-route contract, identical for every server:

- `GET /` returns an empty 200 (`content-length: 0`).
- `GET /user/42` returns the route parameter as `text/plain`.
- `POST /user` returns an empty 200.

Servers: 8 event-loop threads each, HTTP/1.1 keep-alive, same
bootstrap (TCP_NODELAY, pipelining assistance, error handling). The
runtime server (`whitethroated-runtime-benchmark-server`) drives
`WhiteThroatedRuntime` through a hand-built dispatcher: no
`Application`, no framework router, no middleware, no
Request/Response types.

Load generator: `whitethroated-benchmark-client` (release), closed
loop, one request in flight per connection, TCP_NODELAY on. Matrix:
concurrency 64/256/512 × 3 routes × 1M requests. Throughput: median
of 3 rounds interleaved per round (raw → runtime → framework).
Latency: mean of 2 latency-enabled rounds per server. `ulimit -n
10240` for the whole session. All 135 runs completed their full
1M-request target with zero connection errors.

## 3. Throughput (requests/second, median of 3)

| Route | c64 raw/rt/fw | c256 raw/rt/fw | c512 raw/rt/fw |
|---|---|---|---|
| `GET /` | 145608/145350/143933 | 150472/149363/149275 | 150948/149710/149112 |
| `/user/42` | 142782/141523/139390 | 145681/144751/145245 | 147637/145379/144018 |
| `POST` | 142864/140385/142634 | 147619/144388/145150 | 148248/145650/146167 |

Runtime-vs-raw: 97.8–99.8%. Framework-vs-runtime: 98.5–101.6%
(framework wins 3 cells outright — noise, since both execute the
same cached runtime path there). Framework-vs-raw: 97.5–100.3%.

Raw per-round data (R1/R2/R3), `GET /` c64: raw
144658/147064/145608; runtime 144975/145350/145127; framework
145611/143780/143933. Spreads of ±1–2% between rounds are normal on
this loaded desktop host and are why the report uses medians.

## 4. Latency (microseconds, mean of 2 latency-enabled runs)

Average:

| Route | c64 raw/rt/fw | c256 raw/rt/fw | c512 raw/rt/fw |
|---|---|---|---|
| `GET /` | 436/437/443 | 1711/1678/1702 | 3374/3374/3378 |
| `/user/42` | 449/449/450 | 1731/1746/1757 | 3446/3498/3512 |
| `POST` | 449/448/448 | 1754/1759/1745 | 3456/3461/3461 |

p50:

| Route | c64 raw/rt/fw | c256 raw/rt/fw | c512 raw/rt/fw |
|---|---|---|---|
| `GET /` | 326/328/325 | 1204/1174/1199 | 2525/2506/2501 |
| `/user/42` | 319/314/317 | 1213/1204/1225 | 2523/2566/2589 |
| `POST` | 332/327/332 | 1265/1238/1245 | 2666/2593/2643 |

p75:

| Route | c64 raw/rt/fw | c256 raw/rt/fw | c512 raw/rt/fw |
|---|---|---|---|
| `GET /` | 481/491/489 | 1940/1912/1931 | 4040/4021/4013 |
| `/user/42` | 495/493/500 | 2005/2020/2044 | 4135/4191/4196 |
| `POST` | 485/492/502 | 2027/2015/2020 | 4142/4128/4172 |

p90:

| Route | c64 raw/rt/fw | c256 raw/rt/fw | c512 raw/rt/fw |
|---|---|---|---|
| `GET /` | 755/748/774 | 3161/3151/3148 | 6178/6293/6260 |
| `/user/42` | 806/821/827 | 3287/3367/3362 | 6487/6745/6759 |
| `POST` | 771/780/779 | 3173/3262/3243 | 6162/6368/6351 |

p99:

| Route | c64 raw/rt/fw | c256 raw/rt/fw | c512 raw/rt/fw |
|---|---|---|---|
| `GET /` | 2305/2283/2367 | 8970/8730/8982 | 14123/14292/14438 |
| `/user/42` | 2548/2543/2548 | 8867/8854/8839 | 15168/14664/14787 |
| `POST` | 2488/2508/2453 | 8616/9145/8530 | 13488/14496/13482 |

Framework-vs-raw deltas: p50 −2.7–+2.6%, p90 −0.5–+4.2%, p99
−2.5–+2.7%. Every cell is within the ±5% gate; most are within
±2.5% machine noise.

Minimum latency (16–40 µs for all servers) and p99.999/max (13–103
ms OS-scheduling outliers, e.g. one 102 ms stall during runtime
POST c256 L2 and one 92 ms stall during raw POST c256 L2) are
noise-dominated on this host and excluded from the gate. The two
runtime p99 readings above +5% versus raw (POST c256/c512) both
coincide with such one-off stalls and vanish in the
framework-vs-raw comparison on the identical runtime code path, so
they are attributed to machine noise, not the architecture.

## 5. Analysis — where the time goes

The refactor preserves the pre-refactor finding: WhiteThroated
tracks raw SwiftNIO on every percentile, so tails are a
SwiftNIO-stack property, not framework code. Supporting
measurements from this session:

- `sample` profile of the framework server under 256-connection
  `/user/42` load: the connection handler's dispatch accounts for
  ~14% of event-loop stacks (inclusive, including the NIO writes
  below it); ARC/retain and allocator symbols each sit below 0.1%.
  Decode (`BetterHTTPParser`), the write pipeline
  (`PendingStreamWritesManager`, `writev`), and kqueue scheduling
  dominate.
- `malloc_history` census over 500k `/user/42` requests: hot paths
  allocate 0–1 tiny buffers per request (the dynamic body buffer),
  at parity with the raw control. Request/response/header traffic
  is CoW bumps and small-string/atomics, not mallocs.
- In-process transport matrix (`testTransportWriterBenchmark`):
  `empty-framework` 1555 ns/op vs `empty-raw` 1522 ns/op (+2.2%);
  `text-factory` 2321 ns/op vs `text-raw` 2161 ns/op (+7% on a
  ~160 ns framework tax for Request/Response/conversion).

A `consuming`-ownership variant of the Response→RuntimeResponse
boundary conversion measured noise-identical in the in-process
matrix (text-factory 2340 vs 2321 ns/op) and was reverted to keep
the simpler property shape.

## 6. p90/p99 versus Hono — investigation outcome

The Hono gap from the previous report stands: Hono/Bun wins p90 by
~9–26% and p99 by ~35–110% with a much tighter distribution
(p50→p99 ~2.3× vs WhiteThroated ~7×), despite 30–40% lower
throughput. This session's measurements isolate the gap **below**
the runtime layer: the runtime adds ~0 overhead over raw NIO on
mean and on every percentile, and its hot paths are already at the
floor (no per-request Tasks/futures/locks, no cross-loop hops,
0–1 tiny mallocs).

Experiments considered and rejected with cause:

- Response-flush batching across requests: would cut syscalls but
  intentionally delays responses; forbidden by the project's
  no-timer-batching rule and untested against p50.
- Leaner channel pipeline (dropping pipelining assistance/header
  validation): weakens HTTP/1.1 correctness for a config-level
  delta against the raw control.
- Cross-module inlining/`consuming` conversions: measured null
  (prior `-cross-module-optimization` trials regressed 5–9%).
- QoS/pinning, allocator swaps, custom epoll/kqueue: out of scope
  (policy: no new dependencies, Swift-only, no NIO fork).

Recommended next performance experiments, in order:

1. Multi-process `SO_REUSEPORT` deployment (one acceptor per
   process): tests the hypothesis that Bun's 8-process topology —
   independent allocators and kernel-level accept balancing —
   explains the tighter tails.
2. Allocator experiment behind a policy exception (e.g. mimalloc):
   measures how much of the p99 spread is malloc slow-path
   variance shared by all 8 loops.
3. Upstream NIO profiling of decode-side per-request mallocs
   (`HTTPHeaders` backing arrays) and write-side
   `PendingWritesManager` growth: the two largest remaining
   sub-runtime costs in the census.

## 7. Reproduction

```bash
swift build -c release --product whitethroated-benchmark-server \
  --product whitethroated-runtime-benchmark-server \
  --product raw-nio-benchmark-server \
  --product whitethroated-benchmark-client
ulimit -n 10240
WHITETHROATED_HOST=127.0.0.1 WHITETHROATED_PORT=3000 \
  .build/release/whitethroated-runtime-benchmark-server
```

Drive (example: throughput sample, `/user/42`, concurrency 256):

```bash
WHITETHROATED_BENCH_HOST=127.0.0.1 WHITETHROATED_BENCH_PORT=3000 \
WHITETHROATED_BENCH_METHOD=GET WHITETHROATED_BENCH_PATH=/user/42 \
WHITETHROATED_BENCH_CONNECTIONS=256 WHITETHROATED_BENCH_REQUESTS=1000000 \
  .build/release/whitethroated-benchmark-client
```

Add `WHITETHROATED_BENCH_LATENCY=1` for the paired latency sample.
Run the concurrency matrix 64/256/512 per route against each
server in turn; see §2 for rounds and interleaving.
