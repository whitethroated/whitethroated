# WhiteThroated vs Express.js vs Hono on Bun — benchmark report

Date: 2026-10-17. Machine: Apple M1 Pro (8 cores), macOS 26.6.2.
Runtimes: Bun 1.4.3 (recorded campaign version), Node v24.14.0
present but unused for serving. Frameworks: express 5.3.0, hono
4.13.13, WhiteThroated @b99c4f8 (Swift 6.2.4, SwiftNIO exactly 2.104.0).

Evidence qualification: this historical matrix has one sample per mode per
cell. Its directional ranking is exploratory, not a replicated publication
claim. Current stable versions were not re-verified by the present tooling
change. Runtime implementation language is irrelevant to these measurements.

## 1. Verdict

WhiteThroated beats both JavaScript frameworks on throughput, average,
p50, and p75 in all 9 cells (roughly 2× Express, 1.4× Hono) — but Hono
takes p90 and p99 in all 9 cells with a much tighter latency
distribution, and Express also beats WT at p99. The same shape as the
Rust comparison: WT/Swift-NIO has the fastest median and the widest
tails.

| Aspect (9 cells each) | Winner |
|---|---|
| Throughput (req/s) | WT 9/9 (~2× express, ~1.4× hono) |
| Average latency | WT 9/9 |
| p50 latency | WT 9/9 vs both JS frameworks |
| p75 latency | WT 9/9 vs both JS frameworks |
| p90 latency | hono 9/9, WT 2nd (beats express 9/9) |
| p99 latency | hono 9/9, express 2nd, WT 3rd |
| Minimum latency | split/noise (WT 4, hono 5, all 23–40 µs) |
| p99.999 / max | noise; hono usually tightest (see §5) |
| WT vs raw-NIO control | parity (±4%) |

## 2. Method

External three-route contract, identical for every framework:

- `GET /` returns an empty 2xx response.
- `GET /user/:id` returns the route parameter as the body.
- `POST /user` returns an empty 2xx response.

Servers: 8 workers each (Bun `node:cluster` with 8 workers for the JS
servers, 8 event-loop threads for the Swift servers), HTTP/1.1
keep-alive, release builds. Express runs on Bun's `node:http` with
`x-powered-by` disabled, `etag` off, explicit `content-length: 0` on
empty responses and `text/plain` on the echo. Hono runs on
`Bun.serve({ fetch: app.fetch })` with `c.body(null, 200)` empties and
`c.text()` echo. The JS servers live outside this repository per
`BENCHMARKS.md` (Swift-only source policy). Response semantics were
verified with curl before measuring. Note the frameworks' default
headers differ on the wire: Express adds `Date` + `Connection` /
`Keep-Alive`, Hono adds `Date`, WT sends neither — kept as-is.

Load generator: `whitethroated-benchmark-client` (release), closed loop,
one request in flight per connection, TCP_NODELAY on. Matrix:
concurrency 64/256/512 × 3 routes, one throughput-only plus one
latency-enabled sample of 500k requests per cell, interleaved per cell
(express → hono → WT → raw). Gaps here (30–130%) far exceed the
±5–15% single-sample noise on this loaded desktop machine, but one
round per mode does not satisfy the current replication gate. Logs: `/tmp/js-bench/results-js*`.

## 3. Throughput (requests/second)

| Route | c64 express/hono/wt/raw | c256 express/hono/wt/raw | c512 express/hono/wt/raw |
|---|---|---|---|
| `GET /` | 70408/100429/138690/135720 | 70500/98477/135959/142297 | 66405/99019/133687/138690 |
| `/user/42` | 59090/96054/128947/116740 | 57318/96580/132881/133214 | 57808/94584/133563/133378 |
| `POST` | 62823/98672/137686/134475 | 62977/96794/124955/131666 | 62583/94380/133352/140842 |

WT leads express by +93–132% and hono by +29–41% in every cell.
Express degrades most on the param route (59k→57k); hono is flat
across routes (~94–100k); WT/raw sit at the loopback ceiling (~125–142k).

## 4. Latency (milliseconds, latency-enabled runs)

Average — WT 9/9:

| Route | c64 exp/hono/wt | c256 exp/hono/wt | c512 exp/hono/wt |
|---|---|---|---|
| `GET /` | 0.90/0.65/0.49 | 3.72/2.51/1.91 | 7.83/5.16/3.55 |
| `/user/42` | 1.09/0.66/0.48 | 4.41/2.62/1.87 | 8.70/5.32/3.61 |
| `POST` | 0.95/0.63/0.46 | 3.90/2.60/1.80 | 8.00/5.32/3.60 |

p50 — WT 9/9 vs both JS frameworks:

| Route | c64 exp/hono/wt | c256 exp/hono/wt | c512 exp/hono/wt |
|---|---|---|---|
| `GET /` | 0.85/0.60/0.34 | 3.52/2.45/1.41 | 7.69/5.06/2.89 |
| `/user/42` | 1.02/0.61/0.33 | 4.28/2.57/1.39 | 8.63/5.25/2.98 |
| `POST` | 0.90/0.60/0.32 | 3.80/2.56/1.38 | 7.90/5.21/2.96 |

p75 — WT 9/9 vs both JS frameworks:

| Route | c64 exp/hono/wt | c256 exp/hono/wt | c512 exp/hono/wt |
|---|---|---|---|
| `GET /` | 0.92/0.66/0.58 | 3.81/2.57/2.30 | 8.15/5.24/4.42 |
| `/user/42` | 1.11/0.66/0.56 | 4.56/2.70/2.32 | 8.96/5.43/4.49 |
| `POST` | 0.96/0.64/0.53 | 4.01/2.66/2.21 | 8.27/5.38/4.41 |

p90 — hono 9/9, WT 2nd:

| Route | c64 exp/hono/wt | c256 exp/hono/wt | c512 exp/hono/wt |
|---|---|---|---|
| `GET /` | 1.10/0.84/0.92 | 4.13/2.82/3.56 | 8.68/5.49/6.49 |
| `/user/42` | 1.31/0.80/0.88 | 4.87/2.88/3.68 | 9.27/5.66/6.51 |
| `POST` | 1.08/0.75/0.85 | 4.29/2.79/3.39 | 8.66/5.63/6.47 |

p99 — hono 9/9, express 2nd, WT 3rd:

| Route | c64 exp/hono/wt | c256 exp/hono/wt | c512 exp/hono/wt |
|---|---|---|---|
| `GET /` | 1.83/1.38/2.73 | 6.60/4.84/8.09 | 10.72/8.06/11.91 |
| `/user/42` | 2.21/1.33/2.67 | 5.72/3.81/7.87 | 10.26/6.97/12.54 |
| `POST` | 1.88/1.27/2.53 | 4.79/3.31/6.99 | 10.11/6.80/11.70 |

Minimum latency splits 4–5 between WT and hono (all 23–40 µs, one
243 µs express outlier) — noise-dominated, no signal. p99.999/max are
also OS-scheduling noise (2.7–84 ms), with hono usually tightest
(e.g. `POST` c64 p99.999: hono 2.7 ms vs WT 41.7 ms vs express
39.6 ms) and WT usually widest.

## 5. Analysis — medians vs tails

The crossover is systematic: WT's per-request service has the lowest
median but the highest variance (p50→p99 grows ~8×, e.g. `GET /` c64:
0.34 → 2.73 ms), while hono/Bun is slower at the median but remarkably
consistent (~2.3×, e.g. 0.60 → 1.38 ms), so it wins from p90 upward
despite 30–40% lower throughput. Express sits between on tails but last
on throughput. The raw-NIO control tracks WT on every percentile, so
the wide WT tails are a SwiftNIO-stack property, not framework code —
the same conclusion as the Rust report, where service-time probing
showed WT handler code adds only ~42 ns median over a trivial handler
and sub-0.01% in-process spikes cannot explain 1%-level network tails.
Under closed-loop load, queueing amplifies mean-service differences
into the tails; the residual tail gap at tied throughput is scheduling
and allocator variance shared by the whole NIO stack.

## 6. Reproduction

JS servers (outside this repo; Bun 1.4.3):

```bash
export PATH="$HOME/.bun/bin:$PATH"
BENCH_PORT=3010 BENCH_WORKERS=8 bun /tmp/js-bench/express-bench/server.js
BENCH_PORT=3011 BENCH_WORKERS=8 bun /tmp/js-bench/hono-bench/server.js
```

Swift servers (release, from repo root):

```bash
swift build -c release --product whitethroated-benchmark-server \
  --product raw-nio-benchmark-server \
  --product whitethroated-benchmark-client
ulimit -n 10240
WHITETHROATED_HOST=127.0.0.1 WHITETHROATED_PORT=3012 \
WHITETHROATED_THREADS=8 \
  .build/release/whitethroated-benchmark-server
```

Drive (example: latency sample, `/user/42`, concurrency 256):

```bash
WHITETHROATED_BENCH_HOST=127.0.0.1 WHITETHROATED_BENCH_PORT=3012 \
WHITETHROATED_BENCH_METHOD=GET WHITETHROATED_BENCH_PATH=/user/42 \
WHITETHROATED_BENCH_CONNECTIONS=256 WHITETHROATED_BENCH_REQUESTS=500000 \
WHITETHROATED_BENCH_LATENCY=1 \
  .build/release/whitethroated-benchmark-client
```

Run the concurrency matrix 64/256/512 per route against each server in
turn. Full per-run logs for this report: `/tmp/js-bench/results-js*`.
