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

## 8. Concrete multi-port topology transfer procedure (pending execution)

Current runtime bootstrap has **no SO_REUSEPORT switch**. Section 5B requires a
separate Linux-only, benchmark-scoped implementation plus accepted-connection
instrumentation and compatibility tests before it can run. Do not launch today's
binary repeatedly on the same port and label that a reuseport experiment. The
multi-port control below works with the existing products; all Linux results
remain pending.

Build the merge tool too:

```sh
swift build -c release --product whitethroated-benchmark-merge
```

Use a dedicated directory per campaign. Record `git rev-parse HEAD` before and
after every topology; stop if it changes. Save the worktree diff and exact build
commands. Record metadata before load (commands are documentation, not scripts):

```sh
uname -a
cat /etc/os-release
lscpu
lscpu -e
numactl --hardware
free -b
swift --version
bun --version
cat Package.resolved
ulimit -a
systemd-detect-virt
cat /proc/sys/kernel/random/boot_id
cat /proc/stat
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/intel_pstate/no_turbo
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_fin_timeout
```

Unavailable tools/files are recorded as unavailable, never invented. Record
competitor package versions from their actual lockfiles. On ARM, turbo controls
may use different files or be unavailable. Save `/proc/stat` again after load to
compute steal-time deltas. Capture host and client metadata separately if remote.

Example `4×2` launch, repeated manually for ports 3100, 3101, 3102, 3103:

```sh
WHITETHROATED_HOST=127.0.0.1 WHITETHROATED_PORT=3100 WHITETHROATED_THREADS=2 \
  .build/release/whitethroated-benchmark-server > /tmp/worker-3100.log 2>&1 &
```

Retain every PID and terminate/reap only those workers after the cell. Verify
readiness and response bytes on every port. Replace the product with runtime/raw
for controls. Topology mapping at a fixed eight client shards:

| Topology | Worker ports | Loops per worker | Shard i destination |
|---|---|---|---|
| 1×8 | 3100 | 8 | 3100 |
| 2×4 | 3100–3101 | 4 | 3100 + i % 2 |
| 4×2 | 3100–3103 | 2 | 3100 + i % 4 |
| 8×1 | 3100–3107 | 1 | 3100 + i % 8 |

Start eight client processes concurrently (i = 0…7). Each gets 125000 requests;
connections per shard are 8, 32, 64 for total 64, 256, 512. Keep client thread
count identical across cells; one per shard gives eight client loops total.
Warm all worker ports before each cell. Example shard 0, latency mode:

```sh
WHITETHROATED_BENCH_HOST=127.0.0.1 WHITETHROATED_BENCH_PORT=3100 \
WHITETHROATED_BENCH_METHOD=GET WHITETHROATED_BENCH_PATH=/ \
WHITETHROATED_BENCH_CONNECTIONS=32 WHITETHROATED_BENCH_REQUESTS=125000 \
WHITETHROATED_BENCH_THREADS=1 WHITETHROATED_BENCH_LATENCY=1 \
WHITETHROATED_BENCH_RUN_ID=framework-4x2-root-c256-r1-lat \
WHITETHROATED_BENCH_OUTPUT=/tmp/campaign/r1-shard-0.json \
  .build/release/whitethroated-benchmark-client > /tmp/campaign/r1-shard-0.log 2>&1 &
```

Wait for all eight client exit statuses; any failure invalidates the cell. Pool
with the command in BENCHMARKS.md. Repeat separately with latency disabled for
throughput. Rotate topology order over at least three rounds (five for effects
under 10%). Repeat the three contract routes. Compare competitor topologies
through the same eight-shard client, with verified accept distribution.

For each worker sample `/proc/PID/status` (VmRSS, VmHWM, switch counts),
`/proc/PID/stat` (utime/stime), `/proc/PID/schedstat`, and per-thread equivalents
before/after load. Use deltas for cumulative counters. Poll RSS during load,
report idle/post/maximum simultaneous aggregate RSS separately from the sum of
per-worker high-water marks. The latter may overstate simultaneous peak.
Capture `pidstat -u -w -t -p PID 1` and, in separate profiling rounds:

```sh
perf stat -p PID -e task-clock,cycles,instructions,branches,branch-misses,cache-misses,context-switches,cpu-migrations,page-faults -- sleep 20
```

Attach to all worker PIDs for aggregate counters. Record permissions and enabled
counter support; do not treat multiplexed or VM-distorted counters as definitive.
Unprofiled rounds own latency claims. Compute requests/CPU-second from summed
worker utime+stime deltas and memory/connection from aggregate RSS with the idle
baseline reported. Keep client costs separate. Scheduler/cache correlations do
not by themselves prove causation.

## 9. Open-loop and expanded REST gates (pending)

The current client remains closed-loop. Raw-sample export does not turn it into
an open-loop generator. Before implementing one, define scheduled-arrival latency
(from intended send time), achieved/offered load, bounded queue admission,
backlog/queue growth, missed arrivals, explicit timeouts and all error counts.
Validate the generator against a deliberately delayed server to catch coordinated
omission. Then use equal absolute offered RPS across frameworks at 50/70/85/95%
and saturation relative to a recorded reference capacity; also report each
framework's own capacity. Preserve the closed-loop continuity matrix.

REST expansion remains incremental: existing small JSON, parameters and query
routes are starting points; medium JSON, headers, JSON request decoding,
middleware 0/1/5/10, sync/async and equivalent small streaming need verified
cross-server status/header/body contracts before comparative claims. A static
JSON string response is serialization of fixed bytes, not Codable encode/decode
performance. Do not compare prepared fixed bytes against per-request encoding
without naming the difference.

### Complete single-cell command example

This POSIX shell example is documentation only. It is not a repository script.
Run from the repository root on the benchmark host. Change `workers`, `loops`,
`connections`, `method`, `route`, `mode`, and the unique run ID per cell. Keep
`workers * loops = 8`. Do not run two cells concurrently. Warmup is 10000 requests
per worker; record that count and use it consistently across frameworks.

```sh
(
set -eu
ulimit -n 10240
workers=4
loops=2
connections=256
method=GET
route=/
mode=1
run_id=framework-4x2-root-c256-r1-lat
results=/tmp/campaign-unique
mkdir -p "$results"
server=.build/release/whitethroated-benchmark-server
client=.build/release/whitethroated-benchmark-client
baseline=$(git rev-parse HEAD)
worker_pids=""
client_pids=""
cleanup() {
  for pid in $client_pids $worker_pids; do kill "$pid" 2>/dev/null || true; done
  for pid in $client_pids $worker_pids; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT HUP INT TERM
worker=0
while [ "$worker" -lt "$workers" ]; do
  port=$((3100 + worker))
  WHITETHROATED_HOST=127.0.0.1 WHITETHROATED_PORT=$port WHITETHROATED_THREADS=$loops \
    "$server" > "$results/$run_id-worker-$worker.log" 2>&1 &
  worker_pids="$worker_pids $!"
  worker=$((worker + 1))
done
sleep 1
worker=0
while [ "$worker" -lt "$workers" ]; do
  WHITETHROATED_BENCH_PORT=$((3100 + worker)) WHITETHROATED_BENCH_PATH="$route" \
  WHITETHROATED_BENCH_METHOD="$method" WHITETHROATED_BENCH_THREADS=1 \
  WHITETHROATED_BENCH_REQUESTS=10000 WHITETHROATED_BENCH_CONNECTIONS=8 \
    "$client" > "$results/$run_id-warm-$worker.log" 2>&1
  worker=$((worker + 1))
done
[ "$(git rev-parse HEAD)" = "$baseline" ]
shard=0
while [ "$shard" -lt 8 ]; do
  output="$results/$run_id-shard-$shard.json"
  [ ! -e "$output" ]
  WHITETHROATED_BENCH_PORT=$((3100 + shard % workers)) \
  WHITETHROATED_BENCH_PATH="$route" WHITETHROATED_BENCH_METHOD="$method" \
  WHITETHROATED_BENCH_CONNECTIONS=$((connections / 8)) \
  WHITETHROATED_BENCH_REQUESTS=125000 WHITETHROATED_BENCH_THREADS=1 \
  WHITETHROATED_BENCH_LATENCY=$mode WHITETHROATED_BENCH_RUN_ID="$run_id" \
  WHITETHROATED_BENCH_OUTPUT="$output" \
    "$client" > "$results/$run_id-shard-$shard.log" 2>&1 &
  client_pids="$client_pids $!"
  shard=$((shard + 1))
done
failed=0
for pid in $client_pids; do wait "$pid" || failed=1; done
client_pids=""
[ "$failed" -eq 0 ]
[ "$(git rev-parse HEAD)" = "$baseline" ]
.build/release/whitethroated-benchmark-merge 8 "$results/$run_id"-shard-*.json \
  > "$results/$run_id-pooled.json"
)
```

A readiness/warmup failure aborts the cell; inspect it before retrying. The fixed
sleep is startup allowance, not a successful readiness assertion. For production
Linux recommendations, complete the CPU/memory/accept instrumentation above as
well as this throughput/latency procedure.
