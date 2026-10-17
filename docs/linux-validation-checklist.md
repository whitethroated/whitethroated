# Linux Performance Validation Checklist

Status: **PENDING — no Linux measurements exist yet.**
Do not present macOS numbers as Linux evidence.
Docker Desktop, Linux VMs, and GitHub-hosted CI are compatibility environments only;
they are not authoritative benchmark hosts for p90/p99 claims.

Reference pins from the macOS campaign (re-verify on the Linux host, then record exact):

- Swift: local 6.2.4, CI image 6.4.0
- SwiftNIO: 2.104.0 (`Package.resolved`)
- Bun: 1.4.3
- Hono: 4.13.13
- Express: 5.3.0

## 1. Host classification

Prefer, in order:

1. Dedicated bare-metal machine.
2. Dedicated-vCPU cloud instance.
3. Controlled VM with pinned resources.
4. Shared VPS for exploratory measurements only (monitor steal time,
   run extra rounds, document variance, never publish p99 from it unless
   the effect clearly exceeds the noise).

## 2. Host metadata to record

Distribution, kernel version, CPU model, physical cores, logical cores,
CPU topology, NUMA topology, RAM, Swift version, SwiftNIO version,
Bun version, Hono version, Express version, compiler flags,
CPU frequency governor, turbo state where observable,
`ulimit -n` / `ulimit -u`, relevant networking sysctls
(`net.core.somaxconn`, `net.ipv4.tcp_*`, `fs.file-nr`),
virtualization status, and CPU steal time if virtualized.

## 3. Build

```sh
swift build -c release --product whitethroated-benchmark-server
swift build -c release --product raw-nio-benchmark-server
swift build -c release --product whitethroated-runtime-benchmark-server
swift build -c release --product whitethroated-benchmark-client
swift test -c release
```

All tests must be green before any benchmark claims.
Set `ulimit -n 10240` (or higher) before high-concurrency cells.

## 4. Benchmark contract

HTTP/1.1 keep-alive, one request in flight per connection (closed-loop),
identical Host/header shape, release builds only.

Routes:

- `GET /` → empty 200, `content-length: 0`
- `GET /user/42` → `42` as `text/plain`
- `POST /user` → empty 200, `content-length: 0`

Concurrency matrix: 64, 256, 512. Target 1,000,000 requests per cell.
At least 3 interleaved rounds; medians for throughput; full latency
distributions (avg, p50, p75, p90, p99, max, errors).

Servers under test:

1. raw SwiftNIO
2. WhiteThroatedRuntime
3. WhiteThroated
4. Hono on Bun
5. Express on Bun

### 4.1 Swift servers

```sh
WHITETHROATED_HOST=127.0.0.1 WHITETHROATED_PORT=3000 \
  WHITETHROATED_THREADS=<loops> \
  .build/release/<server-product>
```

Omit `WHITETHROATED_THREADS` for the default loop count.

### 4.2 Swift client

```sh
WHITETHROATED_BENCH_HOST=127.0.0.1 WHITETHROATED_BENCH_PORT=3000 \
  WHITETHROATED_BENCH_METHOD=GET WHITETHROATED_BENCH_PATH=/ \
  WHITETHROATED_BENCH_CONNECTIONS=256 WHITETHROATED_BENCH_REQUESTS=1000000 \
  WHITETHROATED_BENCH_THREADS=<n> WHITETHROATED_BENCH_LATENCY=1 \
  .build/release/whitethroated-benchmark-client
```

Defaults: port 3000, path `/prepared`, method `GET`, requests 1000000,
connections 128, threads = core count, TCP_NODELAY on (set
`WHITETHROATED_BENCH_TCP_NODELAY=0` to disable).
Set `WHITETHROATED_BENCH_LATENCY=1` for latency distributions.

### 4.3 Bun servers (recreate on host; JS bench sources are /tmp-only)

Match the macOS contract exactly:

- `GET /` → empty 200 with `content-length: 0`
- `GET /user/:id` → id echoed as `text/plain`
- `POST /user` → empty 200 with `content-length: 0`
- Express: `x-powered-by` disabled, `etag` disabled
- `BENCH_PORT` / `BENCH_WORKERS` env vars, `node:cluster` fan-out,
  bind `127.0.0.1`

Record exact Bun/Hono/Express versions. Do not tune one side only.

## 5. Topology validation (first Linux experiment)

Test 1×8, 2×4, 4×2, 8×1 (processes × loops per process) at constant
total loops. Mirror the macOS sharded apparatus (see
`docs/benchmark-raw-runtime-framework-2026-10-17.md` and `BENCHMARKS.md`):
one client shard per worker port, compare topologies only through the
identical apparatus.

Compare:

- A. one process × N loops (control),
- B. N processes on one port via `SO_REUSEPORT`,
- C. N processes on N ports (explicit sharding).

For B, verify accept distribution per worker (e.g. count ESTABLISHED
sockets per worker PID with `ss -tnp` during load). Balanced delivery is
required before comparing B against C; a 256/0/0/… skew invalidates B.

Measure per topology: RPS, avg, p50, p75, p90, p99, RSS, peak RSS,
CPU utilization, voluntary/involuntary context switches, CPU migrations.

## 6. Scheduler/cache investigation

Collect alongside topology runs where tooling permits:

- `perf stat`: task-clock, cycles, instructions, branches, branch-misses,
  cache-misses, context-switches, cpu-migrations, page-faults
- `pidstat -w -u` per worker: voluntary/involuntary switches, %CPU
- `/proc/<pid>/schedstat`, runqueue latency where available

Normalize counters per request and per CPU second. Correlate tail
changes with scheduler/cache deltas; do not claim causality from
topology alone.

## 7. Rules

- No OS/kernel tuning that favors one server; shared tuning applies to
  all sides, WhiteThroated-only tuning is a separate labeled experiment.
- Same physical host, same builds, same pins, same pins recorded.
- Warm each server; interleave rounds; report medians and variance.
- If machine noise exceeds an observed delta, the verdict is
  inconclusive (C), not a win.
- Final verdict must be exactly one of: (A) WhiteThroated wins all
  targeted metrics, (B) wins throughput/median but loses specific tails,
  (C) inconclusive on variance.
