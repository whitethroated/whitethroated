# Per-topology scheduler evidence: switches flat, user CPU falls

Date: 2026-10-17. Host: Apple M1 Pro, macOS. Framework server,
`GET /`, identical 8-shard apparatus (8 × 32c/125k), 2 rounds with
rotated topology order. Workers run as children of a Swift launcher
(`/tmp/toposched/TopoSchedLauncher.swift`, compiled `/tmp`-only)
that reports `getrusage(RUSAGE_CHILDREN)` after reaping them:
aggregate switch counts + utime/stime for the whole worker set.
60 s lifecycle per topo-round (~25 s load, ~35 s idle tail — idle
dilutes load-phase rusage differences by roughly half, so surviving
effects understate the load-phase gap). 128/128 shards, zero
shortfalls. No privileges, no private APIs.

Pre-flight: pressure 0, ~65 MB free (tight), load ~3.6 falling, no
hogs. R2 caught transient RPS dips on 1×8 (129175) and 4×2
(133996); noted where they pollute means.

## Results (means of 2 rounds; per-round data below)

| topo | RPS    | p50 | p90  | p99   | nivcsw | utime  | stime  |
|------|--------|-----|------|-------|--------|--------|--------|
| 1×8  | 136118 | 530 | 4663 | 17532 | 124612 | 13.03s | 24.47s |
| 2×4  | 144895 | 542 | 4466 | 16763 | 120725 | 12.40s | 23.83s |
| 4×2  | 141067 | 526 | 4278 | 18102 | 127060 | 11.55s | 22.96s |
| 8×1  | 145346 | 555 | 4185 | 17561 | 117090 | 11.06s | 23.43s |

Per-round RPS — R1: 143060/145025/148137/148678 (monotonic);
R2 (reversed): 129175(dip)/144764/133996(dip)/142013.
Per-round p90 — R1: 4709/4462/4267/4143; R2: 4617/4469/4289/4226
(monotonic within both rounds, −10.2% at 8×1).
Per-round utime — R1: 12.73/12.22/11.48/10.93 s;
R2: 13.33/12.58/11.62/11.20 s (monotonic within both rounds,
−15.1% at 8×1 despite the R2 RPS dips landing on other topologies).
Per-round nivcsw — R1: 116913/119943/116930/109366;
R2: 132311/121507/137190/124814 (round-to-round shifts ±8–17%,
topo gaps ≤6% inside round spreads).
p99 flat again (17532/16763/18102/17561, ±4%) at the ~17–18 ms
machine-noise floor. p50 flat-ish (±5%).

## Correlation verdict

The p90 win (−10%, third reproduction) rides on **user-space CPU
reduction (−15%, monotonic both rounds), not on fewer context
switches** (flat/unresolving) or less kernel CPU (stime −2 to −6%,
~flat; more processes cost no kqueue/accept penalty). With ~60%
idle dilution, the load-phase utime gap is larger than the measured
−15%. `RUSAGE_CHILDREN` maxrss (max single child, not a sum)
cross-validates the memory table's per-worker shrink (13.9 → 9.3 MB).

Scheduler-quantity hypothesis (fewer switches ⇒ tighter tails):
REJECTED on macOS at this resolution — switches don't move while
p90 moves 10%.

Redirect: the mechanism lives in user space. Candidates (unproven):
cache locality from smaller per-process working sets, less
cross-thread coherence traffic, less shared-allocator fast-path
contention. The Linux experiment sharpens accordingly: `perf stat`
cycles/IPC/stalled-cycles/cache-misses per topology matter more than
switch/migration counts. If 8×1 shows higher IPC + fewer stalled
cycles at equal switches, locality is confirmed.

## macOS rusage limitation (validated, not assumed)

`ru_nvcsw` is 0 in every cell — including a control child doing
nothing but `Thread.sleep(3)` (nvcsw=0, nivcsw=24). macOS does not
attribute blocking sleeps to voluntary switches via this API, so the
voluntary/involuntary split is nonfunctional here; nivcsw carries
(total) switch activity only. CPU migrations are likewise
unavailable. The vol/invol split and migrations are Linux-only
measurements (`/proc/<pid>/status`, `perf stat`).

## Method appendix

Launcher spawns N workers (ports 3100+, `WHITETHROATED_THREADS`
= loops), polls `/` per port, prints READY, sleeps the lifecycle,
SIGTERMs/SIGKILLs, reaps, prints rusage. Driver
`/tmp/toposched/run.sh` runs the RPS+LAT shard phases between READY
and reap. Latency aggregation: mean-of-shard percentiles. Raw logs
in `/tmp/toposched/` (not in repo).
