# Framework topology × memory table: 1×8 vs 2×4 vs 4×2 vs 8×1

Date: 2026-10-17. Host: Apple M1 Pro, macOS. Framework server,
`GET /`, identical 8-shard client apparatus for every topology:
8 concurrent shards × 32 conns × 125k requests (256 conns / 1M
requests total per cell). RPS = sum of shard RPS; latency =
mean-of-shard percentiles (comparison metric only, per the standing
caveat). 2 rounds, topology order rotated (R1 forward, R2 reverse).
128/128 shards, zero shortfalls.

Pre-flight (marginal window, recorded honestly): memory pressure 193
(nonzero), ~100 MB free, load ~4 falling from ~7, no runaway hogs.
Memory/CPU data are robust to this; latency is directional and the
p99 column specifically sits at the machine-noise floor (see below).

## Results (means of 2 rounds)

| topo | RPS    | ΔRPS  | p50 | p90  | p99   | idleMB | postMB | peakMB | Δmem  | CPU% |
|------|--------|-------|-----|------|-------|--------|--------|--------|-------|------|
| 1×8  | 138454 | —     | 495 | 4607 | 18649 | 8.6    | 13.0   | 13.2   | —     | 235  |
| 2×4  | 141648 | +2.3% | 576 | 4451 | 16693 | 17.0   | 20.5   | 20.5   | +7.5  | 249  |
| 4×2  | 146653 | +5.9% | 553 | 4306 | 17617 | 33.7   | 37.2   | 37.2   | +24.2 | 249  |
| 8×1  | 148639 | +7.3% | 530 | 4099 | 18601 | 66.9   | 71.0   | 71.0   | +58.0 | 239  |

Per-round RPS: R1 134774/140759/145451/149031,
R2 142133/142537/147855/148247 — monotonic within both rounds.
Per-round p90: R1 4550/4478/4212/4113, R2 4663/4425/4399/4086 —
monotonic within both rounds. p50/p99 round detail in
`/tmp/topo-mem/` logs (not in repo).

## Findings

1. RPS improves monotonically with process count: +7.3% at 8×1,
   both rounds monotonic. Reproduce: prior "neutral-to-better".
2. p90 improves monotonically: −11.0% at 8×1, both rounds
   monotonic. Reproduces prior transfer (−3 to −15%).
3. p99 does NOT resolve here: 18649/16693/17617/18601 with 2×4
   nominally best in both rounds. All four sit at ~17–19 ms, the
   machine-noise floor of this marginal window (pressure/load
   hiccups hit every topology equally and wash out server-topology
   p99 differences). This neither confirms nor overturns the prior
   −18 to −34% transfer finding (2 rounds then, 2 rounds now, one
   conflicting data point): p99 magnitude needs quiet-window
   adjudication with the rotated 5-round protocol.
4. p50 slightly favors 1×8 (+5–16%, non-monotonic across doses).
   Consistent with prior "neutral/mixed"; possible small balancing
   cost of partitioning, needs quiet confirmation.
5. Memory scales near-linearly: ~8.6 MB idle per worker
   (≈13 MB post-load for the 8-loop worker, ≈9 MB for 1-loop
   workers — the per-worker shrink is mostly thread stacks).
   Post-load totals: 13.0 → 20.5 → 37.2 → 71.0 MB.
   Peak ≈ post (no transient spikes; growth at warmup, then flat).
6. Total CPU is flat (~235–249%): topology moves neither the work
   nor its cost. 8×1 gains +7% requests-per-CPU-second.

## Deployment guidance (macOS, framework, `/`-like workloads)

- 4×2 is the sweet spot if p99 adjudicates in its favor: +5.9% RPS,
  −6.5% p90, +24 MB total. 8×1 buys another +1.4% RPS / −4.5%
  p90 for +34 MB more — diminishing returns, as before.
- Do not deploy multi-process for p99 on this evidence alone: the
  p99 win is unconfirmed in this window. Deploy for RPS/p90 with
  known memory cost, or wait for quiet-window p99 adjudication.
- p50 pays a small partitioning cost (+7% at 8×1 here).

## Method appendix

Workers: `WHITETHROATED_THREADS=<loops>`,
`WHITETHROATED_PORT=3100..<3100+N-1`, one port per worker (macOS
`SO_REUSEPORT` does not distribute). Shard i → port
`3100 + (i mod Nworkers)`. RSS/CPU via `ps` sampling: idle (ready,
pre-load), ~0.5 s load samples (peak = per-worker max, summed),
post-load; CPU = pooled mean × workers. Orchestrator:
`/tmp/topo-mem/run.sh` (smoke-validated after fixing a bare-`wait`
that also caught the sampler). Client shards excluded from RSS/CPU
(identical across topologies).
