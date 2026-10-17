# WhiteThroated thread tuning vs Hono/Express on Bun — benchmark report

Date: 2026-10-17. Machine: Apple M1 Pro (8 cores: 6P+2E), macOS 26.6.2.
Runtimes: Bun 1.4.3 (Rust rewrite line, latest), express 5.3.0, hono 4.13.13,
WhiteThroated @0d91fde (Swift 6.2.4, SwiftNIO exactly 2.104.0).
Load: `whitethroated-benchmark-client` (release), closed loop, 500k req/cell.

## 1. Verdict

WhiteThroated with **2 event-loop threads** (WT-2, optimal for co-located
saturated loopback load) beats Hono/Bun on throughput, average, p50 and p75
in all 18 replicated samples, and leads p90 12-6. But p99 **ties 9-9**
(WT sweeps c64, Hono sweeps c256) and distribution tightness stays with Hono.
The remaining gaps are structural (see §6), not tunable: no legitimate
configuration or in-scope code change closes them on this machine.

| Aspect (18 samples) | Express/Bun | Hono/Bun | WhiteThroated-2 |
|---|---|---|---|
| Throughput | last 0/18 | 0/18 | **best 18/18** |
| Average | last | 0/18 | **best 18/18** |
| p50 | last | 0/18 | **best 18/18** |
| p75 | last | 0/18 | **best 18/18** |
| p90 | last | 6/18 (c64 only) | **best 12/18** |
| p99 | last | **tied 9/18** | **tied 9/18** |
| Consistency (p99/mean) | widest | **~1.1x, best** | ~1.9x |
| Raw speed | last | 2nd | **best** |

## 2. Thread-count sweep (GET / c256, single samples)

| Server threads | RPS | p90 (ms) | p99 (ms) |
|---|---|---|---|
| WT-8 | 119498 | 3.52 | 7.50 |
| WT-4 | 129245 | 3.11 | 4.99 |
| WT-3 | 145657 | 3.02 | 4.87 |
| **WT-2** | 143205 | **1.94** | **3.42** |
| WT-1 | 84847 | 3.17 | 3.33 |
| Hono (8 nominal) | 102936 | 2.60 | 2.86 |

Fewer threads is superlinear: WT-8 to WT-2 gains +20% RPS and -54% p99.
WT-2 is the goal optimum (WT-3 trades tails for +1% RPS; WT-1 loses RPS).
Two full replicated rounds (R1 order express-hono-WT, R2 reversed) confirm
the §1 scorecard. Logs: `/tmp/wt2-validation/`.

## 3. Bun cluster degenerates to one worker on macOS

During c256 load, `lsof` shows **256/256 server connections on one Bun
worker pid**; `ps cputime` deltas over 5 s show that worker at ~99% of one
core and the other seven at 0.00 s. The nominal "8 workers" is effectively
one. Hono's numbers are therefore single-worker numbers: ~100k RPS at
~99% of one core, i.e. ~9.6-10 us CPU per request.

## 4. CPU per request (measured, GET / c256)

- WT-2: 2.0 saturated cores / 145k RPS = **~13.8 us/req**.
- Hono: 0.99 cores / 103k RPS = **~9.6 us/req**.
- WT-1: 1 core / 84.8k = ~11.8 us/req (uncontended floor).

`sample` self-time on saturated WT-2: `writev` 30%, `read` 27%, ARC
retain/release ~5%, exclusivity/casts/metadata ~5%, llhttp self 0.6%.
Syscalls (1 read + 1 writev per request) sit at the floor both sides pay.

## 5. Mechanism: single-thread self-clocking vs multi-thread decorrelation

Closed-loop load on one thread self-synchronizes into a deterministic
rotation, so p99 ~= 1.1x mean. Proof: WT-1 measures p99/mean **1.08-1.10x**
(user c256: avg 3.47 ms, p99 3.74 ms), matching Hono's 1.14x. WT-2 at
1.9x is wider because preemptions/migrations hit half the connections at
a time (jitter decorrelation), not because of framework code: in-process
diagnostics show framework overhead at ~20 ns on these routes.

## 6. Why c64-p90 and c256-p99 cannot close here

Matching Hono's single-thread tightness at 100k+ RPS needs service <= 10
us/req. WT's uncontended floor is 11.8-13.6 us (syscalls ~8-9 us both
sides; SwiftNIO user-space ~3-5 us heavier: ARC, existentials, allocs,
pipeline hops). The profile caps realistic micro-optimization at ~5%;
the gaps need 10% (c64 p90) and 20% (c256 p99). Client thread counts
(8/6/4/2) were tested and do not move the ranking; multi-process sharding
cannot work on macOS single-port accepts and would hand Hono more
effective workers.

## 7. Integrity note on prior 8v8 reports

`docs/benchmark-whitethroated-express-hono-bun-2026-10-17.md` and the JSON
report present nominal 8-worker Bun comparisons. Their numbers stand, but
the worker framing is corrected by §3: Hono ran one effective worker.
Future macOS comparisons must disclose effective (not nominal) Bun
parallelism; faithful multi-worker Bun needs per-port processes with
sharded load. The WT-2 optimum is specific to co-located saturated
loopback load and is not general production guidance.

## 8. Reproduction

```bash
export PATH="$HOME/.bun/bin:$PATH"
BENCH_PORT=3010 BENCH_WORKERS=8 bun /tmp/js-bench/express-bench/server.js
BENCH_PORT=3011 BENCH_WORKERS=8 bun /tmp/js-bench/hono-bench/server.js
WHITETHROATED_HOST=127.0.0.1 WHITETHROATED_PORT=3012 \
WHITETHROATED_THREADS=2 .build/release/whitethroated-benchmark-server
# per cell, e.g. GET / c256, 500k, throughput-only then WHITETHROATED_BENCH_LATENCY=1:
WHITETHROATED_BENCH_HOST=127.0.0.1 WHITETHROATED_BENCH_PORT=3012 \
WHITETHROATED_BENCH_METHOD=GET WHITETHROATED_BENCH_PATH=/ \
WHITETHROATED_BENCH_CONNECTIONS=256 WHITETHROATED_BENCH_REQUESTS=500000 \
.build/release/whitethroated-benchmark-client
```

Paths that could still move p99/p90 (all outside one-session scope):
Linux re-test (proper accept distribution), upstream SwiftNIO efficiency
work, or a custom transport (high correctness risk, not recommended).
