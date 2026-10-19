# Tier 1 default-transport validation (2026-10-18)

> Socket-option erratum: historical `tcp_nodelay=off` / override `0` labels did not prove TCP_NODELAY was disabled. The old client skipped its override while NIO enabled TCP_NODELAY by default; its explicit `1` used the wrong option level. See [the correction and validation](benchmark-socket-options-2026-10-18.md). Raw measurements are preserved; rebaseline with verified socket values.


Tier 1 is now the preferred HTTP/1 transport. Applications registering any
request-body streaming route use the stock SwiftNIO pipeline for the entire
application. Explicit `useTier1HTTP1Experimental: false` also selects stock.
The historical configuration name remains source-compatible. This change
does not establish a new Express/Hono leaderboard result.

## Correctness and scope

The promotion includes the previously unfinished parser, response-stream,
and file-region work. The chunk-extension grammar and trailer-value checks
are tested against the pinned SwiftNIO decoder. File regions stay zero-copy
`IOData.fileRegion`; response streaming shares length accounting and
event-loop checks with the stock writer. HEAD and bodyless responses,
explicit flushes, declared-length failures, producer errors, HTTP/1.0 close
framing, and pipelined ordering have regression coverage.

An additional audit found that the old Tier 1 handler dispatched pipelined
followers and forwarded socket reads while an async response was pending.
The new handler retains already received bytes and withholds reads until
the response or open response stream ends. It still reads incomplete
request bodies. Disconnect drops pending state; a reentrancy guard keeps
synchronous completion from parsing a follower before request state resets.
The new async/read regression fails on `4acc77c` with both unwanted actions
observed, and passes after the fix. This correctness fix is retained
independently of throughput.

Request-streaming selection tests exercise the same pipeline installer as
production: ordinary keep-alive requests, stock override, incremental
uploads, consumer backpressure, body limits, middleware bypass, and
Content-Length/Transfer-Encoding ambiguity. The standalone Tier 1 handler's
500 guard for request-streaming actions remains covered; the production
bootstrap prevents streaming applications from reaching it.

Fail-safe differences from stock remain explicit: CONNECT/bodyless-status
streams do not start producers; post-end producer writes close; repeatedly
invalid streaming error responses terminate with a fixed 500.

## Build and test evidence

- Linux aarch64, Swift 6.4, SwiftNIO exactly 2.104.0, release mode.
- Full suite: 450 XCTest tests (8 opt-in diagnostics skipped), zero failures;
  102 Swift Testing tests, zero failures. The equivalence suite has 65 tests.
- All five required release products build, including the example, framework
  server, runtime server, raw NIO server, and benchmark client.
- The campaign runner had a pre-existing Swift 6.4 error when accessing
  Glibc's mutable `stdout`. `fflush(nil)` preserves immediate progress output
  without that access. The temporary baseline uses the same compile-only
  fix; its transport sources are unchanged.
- Repeated invalid-stream requests release their recursion keys after mapped
  responses. Pending foreign-loop error futures retain the key until success,
  invalid-stream fallback, or failure completes on the channel event loop.
- Logs: `/tmp/wt-linux/promotion-linux-release-post-cleanup.log`,
  `/tmp/wt-linux/promotion-products-post-cleanup.log`, and
  `/tmp/wt-linux/promotion-read-regression-baseline.log`.

## In-process diagnostic

Active EmbeddedChannels, identical raw GET bytes and response bytes, 1,000
warm-up requests per case, six alternating rounds of 20,000 requests.
These are local pipeline costs including parsing, boundary conversion,
dispatch, and framing, without sockets. Timing outliers remain in the data.

| Response | Stock median ns/op | Tier 1 median ns/op |
|---|---:|---:|
| Synchronous `ok` | 3222 | 1789 |
| Chunked stream `ok` | 4744 | 3881 |

Stock sync rounds span 3176–3555 ns; Tier 1 sync spans 1786–1817 ns.
Stock stream spans 4716–4779 ns; Tier 1 stream spans 3857–4195 ns.
This diagnostic is not a network-throughput claim. See
`/tmp/wt-linux/promotion-linux-pipeline-post-cleanup.log` and the opt-in command in
`BENCHMARKS.md`. CI executes only a smoke-sized version without thresholds.

## Network experiment

Baseline: `4acc77c29655c6a6f408359ff46dfafe62f2d91b`, temporary checkout
outside the repository. Measured production-source diff SHA-256:
`eca917afcc45b84e81e3cec3beb4e0ea0d600f4ca3e67936da91e39542d994d4`.

After this matrix, a cold-path cleanup releases stream-validation error keys
after mapped responses emit and hops foreign error futures to the channel
loop. It adds no ordinary-response check and changes none of the measured
request/response paths. Final production diff SHA-256:
`e65c180a89bf24078f28c816b4491fed1cd823f382d3acf1bd76a30ac1fff2fe`.
The full release suite, pipeline diagnostic, product builds, and final binary
network smoke are repeated after that cleanup; the matrix below identifies
the earlier measured source explicitly.

Apple M1 Pro host; Docker Desktop Linux VM, 8 vCPUs;
Linux `7.0.12-linuxkit`, aarch64; Swift 6.4 release builds using SwiftPM's
SwiftBuild backend. Server processes have two event-loop threads and CPU
affinity 0–3; the same current benchmark client is pinned to CPUs 4–7.
The client requests four threads but uses two loops because of the existing
double `group.next()` behavior; this harness limitation is held constant.
HTTP/1.1, persistent connections, no TLS/compression, client override flag `TCP_NODELAY=0` (effective value unverified).

Each cell has a 20,000-request warm-up followed by separate throughput and
latency samples of 250,000 requests. Four rounds alternate server order.
Concurrency is 64, 256, and 512. The primary matrix covers `GET /`,
`GET /user/42`, and `POST /user` across baseline stock, baseline Tier 1,
current default Tier 1, and unchanged raw NIO. Response-stream controls
compare baseline stock, current forced stock, and current default on
known-length and chunked `Hello, World!` responses. The baseline Tier 1
cannot serve these streams, so it is not a stream control.

Response status, payload, and relevant headers are checked before timing.
The optional response-stream routes are registered on all framework servers.
CPU ticks and process peak RSS are recorded from `/proc` with each sample.
RSS is a process-lifetime high-water mark including earlier warm-up/load,
not a fresh-process peak for each cell.

All 432 measured samples completed: 108 million measured requests with no
client failures. Request counts, body-byte counts, and latency sample counts
were checked for every sample. Startup readiness retries are outside the
measured runs. The tables use medians of four separate runs; latency samples
are not pooled. Full per-round metrics, including p50, p90, p99.999, maximum,
CPU ticks, RSS, and body throughput, are in
[the measurement data](benchmark-data/tier1-default-2026-10-18.json).

Throughput, requests/second (latency collection disabled):

| Route | Connections | Old stock | Old Tier 1 | Current default | Raw NIO |
|---|---:|---:|---:|---:|---:|
| GET / | 64 | 203,664 | 202,248 | 199,148 | 196,847 |
| GET / | 256 | 206,680 | 200,972 | 195,248 | 205,403 |
| GET / | 512 | 187,596 | 198,518 | 188,394 | 203,912 |
| GET /user/42 | 64 | 172,526 | 201,150 | 203,708 | 195,782 |
| GET /user/42 | 256 | 177,696 | 201,876 | 195,313 | 185,049 |
| GET /user/42 | 512 | 175,212 | 189,378 | 196,387 | 186,685 |
| POST /user | 64 | 192,266 | 191,226 | 188,956 | 194,428 |
| POST /user | 256 | 190,680 | 187,680 | 178,070 | 192,308 |
| POST /user | 512 | 184,685 | 183,616 | 183,238 | 183,930 |

p99 cycle latency, microseconds (separate latency-enabled runs):

| Route | Connections | Old stock | Old Tier 1 | Current default | Raw NIO |
|---|---:|---:|---:|---:|---:|
| GET / | 64 | 673 | 863 | 764 | 729 |
| GET / | 256 | 2548 | 2929 | 2538 | 2689 |
| GET / | 512 | 4941 | 5202 | 5037 | 6160 |
| GET /user/42 | 64 | 801 | 695 | 727 | 755 |
| GET /user/42 | 256 | 2851 | 2698 | 2631 | 2661 |
| GET /user/42 | 512 | 6898 | 5053 | 5028 | 5940 |
| POST /user | 64 | 715 | 709 | 788 | 700 |
| POST /user | 256 | 2638 | 2392 | 2448 | 2964 |
| POST /user | 512 | 5734 | 3628 | 5175 | 5328 |

Stream results below are `throughput RPS / p99 microseconds`, taken from
the separate throughput and latency runs respectively:

| Response | Connections | Old stock | Current forced stock | Current default |
|---|---:|---:|---:|---:|
| Known length | 64 | 127,650 / 1284 | 120,894 / 1049 | 141,240 / 938 |
| Known length | 256 | 130,528 / 3020 | 128,141 / 3537 | 141,240 / 3193 |
| Known length | 512 | 127,944 / 5001 | 128,762 / 5596 | 138,387 / 8766 |
| Chunked | 64 | 109,574 / 1102 | 112,207 / 1131 | 122,856 / 1098 |
| Chunked | 256 | 110,691 / 3931 | 111,648 / 4685 | 123,906 / 3673 |
| Chunked | 512 | 109,386 / 7692 | 110,284 / 9863 | 128,152 / 5602 |

For known-length streams at c512, the four current-default p99 values are
10,928 / 15,658 / 6604 / 5545 us, versus old stock
5345 / 16,762 / 4363 / 4657 us. The medians indicate a substantial tail
cost despite higher throughput; the overlapping excursions prevent a clean
mechanism attribution. For chunked streams, current forced-stock c512 p99
also rises in the median, despite approximately neutral throughput.

CPU examples, median process CPU-seconds per 250,000 throughput requests
(100 ticks/second):

| Route / connections | Old stock | Old Tier 1 | Current default | Raw NIO |
|---|---:|---:|---:|---:|
| GET /, 256 | 2.395 | 2.185 | 2.170 | 2.380 |
| GET /user/42, 512 | 2.840 | 2.515 | 2.420 | 2.685 |

Known-length c512 streams use 3.910 CPU-seconds on old stock, 3.880 on
current forced stock, and 3.615 on current default. Maximum observed process
RSS is 24,968 KiB (old stock), 24,084 (old Tier 1), 24,192 (current default),
24,996 (current forced stock), and 24,332 (raw). No material memory growth
appears in this finite workload; it is not a long-duration leak test.

## Interpretation and tradeoff

This is a correctness-backed default selection, **not an overall performance
win**. Ordinary-route throughput versus old Tier 1 ranges from -5.1% to
+3.7% in median, with broad overlapping round spreads. The raw NIO gap is
not reduced on every route. POST c512 median p99 is worse than old Tier 1;
known-length streaming c512 median p99 is worse than both stock controls.
Those signals must not be hidden by the better streaming RPS figures.

The explicit tradeoff is to retain bounded pipelining and the Tier 1
default while preserving the stock override and upload
fallback. This does **not** pass the gate for claiming uniformly faster
throughput or improved tails. The remaining tail investigation and independent
load-generator validation are still open. No cross-framework rankings are
updated from these results.

Raw logs and the external runner remain under `/tmp/wt-linux/`:
`promotion-network/`, `promotion-network.sh`, and the two production diff
snapshots. The tracked JSON preserves all measured per-run metrics without
requiring those temporary files. Reproduce the matrix with the server and
client commands in `BENCHMARKS.md`, both baseline modes, current default,
and raw, retaining the exact routes, affinities, counts, flags, and order above.

## Tail-latency limits

The historical bimodality investigation is diagnostic evidence, not a
resolved mechanism. Additional 500,000-request c512 runs showed Tier 1 p99
between 3418 and 7254 microseconds and Hono between 3809 and 7397
microseconds. Changing the client from four requested threads to three did
not eliminate excursions. Per-connection means were broadly uniform.
These observations do not support a persistent group of slow connections
or a Tier-1-only explanation; they do not prove a scheduler or VM cause.

The exact mechanism remains unresolved. This promotion prioritizes audited
protocol behavior and bounded pipelining, preserves a stock escape hatch,
and makes no claim that the old p99 issue is fixed. Bare-metal Linux with
a separate generator and an independent harness remains necessary before
generalizing VM results or claiming uniformly better tails.
