# Tier-1 Linux verdict: WhiteThroated leads all 8 aspects (2026-10-18)

> Socket-option erratum: historical `tcp_nodelay=off` / override `0` labels did not prove TCP_NODELAY was disabled. The old client skipped its override while NIO enabled TCP_NODELAY by default; its explicit `1` used the wrong option level. See [the correction and validation](benchmark-socket-options-2026-10-18.md). Raw measurements are preserved; rebaseline with verified socket values.


Transport-status update: this is the historical campaign at `4acc77c`.
Tier 1 is now the preferred default, with application-wide stock fallback
for request streaming. The original rankings are not new-default measurements;
see [the default-transport validation](benchmark-tier1-default-2026-10-18.md)
for correctness changes, fresh controls, and the unresolved tail-latency limits.

## Verdict

On isolated-CPU Linux, with the Tier-1 custom HTTP/1 engine enabled
(`WHITETHROATED_TIER1_HTTP1=1`), **WhiteThroated leads all 8 aspects**.
All 54 metric-cells go to a WhiteThroated configuration. Express and Hono
win nothing anywhere, under any worker count tested (2/4/8).

| Aspek       | Winner (isolated Linux + Tier-1)              |
|-------------|-----------------------------------------------|
| Throughput  | WhiteThroated 9/9 (tier1-2 7/9, wt2-stock 2/9) |
| Average     | WhiteThroated 9/9 (wt2-stock 5/9, tier1-2 4/9) |
| p50         | WhiteThroated 9/9 (wt2-stock 6/9, tier1-2 3/9) |
| p75         | WhiteThroated 9/9 (tier1-2 5/9, wt2-stock 4/9) |
| p90         | tier1-2, 9/9                                  |
| p99         | WhiteThroated 9/9 (tier1-2 8/9, wt2-stock 1/9) |
| Konsistensi | WhiteThroated 9/9 (tier1-2 4, wt2-stock 2, tier1-4 2, tier1-8 1) |
| Raw speed   | tier1-2 (peak 221k RPS vs Hono 170k)          |

The former exception cell (`GET /user/42` c512) falls: p99 goes to
tier1-2 (3712us vs Hono 3876us, mean of T1/T2 including one excursion
round), and its consistency goes to tier1-8 (1.10 vs Hono 1.18).

This supersedes the stock-only verdict in
`docs/benchmark-linux-isolated-2026-10-18.md` (52/54 cells). The macOS
Tier-1 A/B report (`docs/benchmark-wt-tier1-http1-2026-10-18.md`) stands
for its environment: co-located macOS noise (+-40% p99) buried a signal
that isolated Linux (+-2-5%) resolves clearly.

## Why Tier-1 matters on Linux but looked neutral on macOS

The NIOHTTP1 pipeline tax is real on Linux and cell-dependent
(tier1-2 vs wt2-stock, T1/T2 means):

- Dynamic route (`GET /user/42`): +12-14% RPS, p99 -15% (c64) to
  -24% (c512, outlier included; median sample -38%).
- Prepared routes: throughput ~neutral to +6%, but p99 -19% to -32%
  at c256/c512; stock keeps a 1-5% mean/p50 edge on `GET /`.
- `POST /user`: +0-2% RPS, p99 -2% to -29%.

Bypassing the decoder / pipelining-assistance / error-handler / encoder
stages removes the bulk of the c512 mid-tail spread (p75-p99) that stock
NIOHTTP1 shows under 512-connection saturation. Tier-1a keeps the
framework dispatcher path (Request/Response conversion), so this win is
purely framing/pipeline bypass, not application shortcuts: echo bodies
verified byte-exact (500k x "42" = 1,000,000 bytes) on every run.

## Setup

Same isolated-Linux rig as the previous verdict: Docker `swift:6.4.0-noble`
(CI image) on Apple M1 Pro 8-core, Bun 1.4.3+c6da4a4d3 (Rust line),
Express 5.3.0, Hono 4.13.13, release builds, 500k req/cell, servers on
CPUs 0-3, client (4 threads) on CPUs 4-7, legacy override flag
`TCP_NODELAY=0` (equal for all, but not an effective off value). The old
wrong-level setsockopt failure was not a VM TCP_NODELAY restriction; see the
socket-option erratum above.

Servers: express-8 (:3010), hono-8 (:3011), wt2-stock (:3012),
tier1-2 (:3020), tier1-4 (:3021), tier1-8 (:3022), hono-2 (:3031),
hono-4 (:3032). Rounds: T1 (forward) + T2 (reversed) full matrix;
T3/T4 c512 consistency sweep; T5/T6 Hono worker-count control;
T7/T8 Hono-2 low-concurrency throughput check.

Client addition (this commit): `WHITETHROATED_BENCH_CONN_STATS=1` prints
per-connection mean deciles plus per-client-loop grouping. Measurement
path untouched; reporting only, after timing ends.

Raw logs: `/tmp/wt-linux/` (T1/T2 full matrix, T3-T8 sweeps, D1/D2
diagnostics; scripts `run-tier1.sh`, `run-c512.sh`).

## Results (T1/T2 means; rps / avg / p50 / p75 / p90 / p99, us)

Root `GET /`:

| c   | express | hono | wt2-stock | tier1-2 |
|-----|---------|------|-----------|---------|
| 64  | 173k/364/326/377/597/824 | 160k/386/359/397/473/804 | 206k/**301/286**/322/**360/624** | **219k**/305/298/**319/358**/647 |
| 256 | 182k/1429/1402/1501/1580/2962 | 170k/1499/1499/1586/1664/2723 | 213k/**1189/1155**/1287/1409/2230 | **216k**/1217/1220/**1286/1401/1508** |
| 512 | 186k/2818/2820/2973/3071/5650 | 157k/3244/3239/3371/3516/3866 | **212k/2350/2343/2590**/2857/4327 | 206k/2477/2435/2607/**2807/3498** |

User-get `GET /user/42`:

| c   | express | hono | wt2-stock | tier1-2 |
|-----|---------|------|-----------|---------|
| 64  | 175k/366/314/412/615/991 | 158k/409/382/419/492/850 | 193k/321/294/**342**/500/639 | **220k/279/250**/350/**411/536** |
| 256 | 180k/1429/1315/1480/2220/3220 | 160k/1592/1584/1677/1772/3012 | 191k/1298/1222/1456/1718/2476 | **215k/1163/1167/1272/1403/2096** |
| 512 | 179k/2874/2711/3034/3231/6085 | 157k/3402/3410/3540/3657/3876 | 190k/2612/2508/2920/3618/4898 | **213k/2323/2278/2402/2680/3712** |

User-post `POST /user`:

| c   | express | hono | wt2-stock | tier1-2 |
|-----|---------|------|-----------|---------|
| 64  | 159k/409/369/415/666/928 | 154k/420/387/429/525/903 | **193k**/329/**309**/357/419/675 | 193k/**317**/313/**332/370/662** |
| 256 | 165k/1583/1550/1634/1718/3253 | 148k/1744/1744/1833/1912/2971 | 195k/**1319/1263/1434**/1620/2591 | **196k**/1375/1374/1459/**1550/1848** |
| 512 | 164k/3254/3251/3387/3509/6404 | 143k/3672/3673/3788/3900/4117 | 194k/**2566/2543/2752**/3035/4640 | **198k**/2656/2610/2803/**3007/3654** |

Consistency (p99/mean; c512 decided by the T3/T4 sweep):

| route/c  | express | hono | wt2-stock | tier1-2 | tier1-4/8 |
|----------|---------|------|-----------|---------|-----------|
| root/64  | 2.26 | 2.08 | **2.07** | 2.12 | - |
| root/256 | 2.07 | 1.82 | 1.88 | **1.24** | - |
| root/512 | 2.01 | 1.11 | 1.88 | 1.21 | **1.10 (t4)** |
| uget/64  | 2.71 | 2.08 | 1.99 | **1.92** | - |
| uget/256 | 2.25 | 1.89 | 1.91 | **1.80** | - |
| uget/512 | 2.12 | 1.18 | 1.88 | 1.58 | **1.10 (t8)** |
| upost/64 | 2.27 | 2.15 | **2.05** | 2.09 | - |
| upost/256| 2.06 | 1.70 | 1.96 | **1.34** | - |
| upost/512| 1.97 | 1.13 | 1.83 | 1.15 | **1.10 (t4)** |

Sweep details (T3/T4 per-round ratios): root tier14 1.111/1.104 vs
hono-8 1.122/1.117; uget tier18 1.105/1.101 vs hono-8 1.245/1.126;
upost tier14 1.114/1.098 vs hono-8 1.161/1.103. WhiteThroated wins both
rounds on all three cells, but root/upost margins are ~0.5-1%: read as
narrow wins, not decisive.

Hono worker-count control (c512, T5/T6): hono-2 is faster (178-198k
RPS) but ragged (ratios 1.14-1.85); hono-4 ratios 1.11-1.19; hono-8
1.11-1.31. No Bun config reaches 1.10. Fewer Bun workers trade
smoothness for speed, exactly like WhiteThroated thread scaling.
Hono-2 throughput check (T7/T8, c64/c256): 184-206k RPS, still below
tier1-2's 193-221k on every cell.

## Mechanism notes (diagnostics, not speculation)

- Per-connection means are uniform on every server (+-1-5% decile
  spread): no cross-loop imbalance, no straggler connections. The
  c512 spread is within-connection per-request jitter.
- All 8 vCPUs measure identical speed (busy-loop): the VM is
  homogeneous; P/E-core theories are falsified for this rig.
- The benchmark client uses only 2 of its 4 event loops (double
  `group.next()` consumption per connect: promise + channel). Equal
  for all servers; fixing it requires re-baselining, so it stays as
  is for this campaign. Filed as future work.
- Tier1-2 `user-get` c512 p99 is bimodal across runs: 4/6 samples at
  ~2900-3070us, 2/6 excursions at ~4427-4456us (T1, T3). Median
  behavior crushes Hono; means still win with excursions included.
  Mechanism unknown; must be understood before Tier-1 productization.

## Caveats (read before quoting)

1. No single WhiteThroated config wins everything: tier1-2 (speed)
   takes 7 aspects plus 6 consistency cells; tier1-4/8 take the 3
   remaining c512 consistency cells at ~25% throughput cost. The same
   speed/smoothness tradeoff exists on the Bun side (hono-2 vs
   hono-8); both families are compared best-config-per-aspect.
2. The three c512 consistency wins are narrow (~0.5-2% per round,
   both rounds consistent). Absolute p99-p50 spread on c512 remains
   tighter on Hono (uniformly-slow lockstep); WhiteThroated wins the
   pre-registered p99/mean ratio metric, helped by its much faster
   mean. Readers valuing absolute predictability should weigh both.
3. Tier-1 remains experimental (`WHITETHROATED_TIER1_HTTP1=1` /
   `useTier1HTTP1Experimental`): correctness-verified (differential
   + equivalence suites, byte-exact bodies at load) but not yet the
   default engine. Default-engine victory stands at 52/54 cells.
4. tier1-2 shows rare p99 excursions on one cell (2/6 runs, also seen
   once on macOS); stock and Hono also showed one excursion each
   across campaigns. Verdict uses round means per methodology.
5. Docker Desktop VM + single-machine load generator: rankings are
   rigorous within this rig; bare metal with a separate generator
   remains the gold standard.

## Reproduction

```sh
docker start wt-linux  # built tree at /work, logs at /out
# servers pinned 0-3 (see /out/diag history), then:
docker exec wt-linux /out/run-tier1.sh T1
docker exec wt-linux /out/run-tier1.sh T2
docker exec wt-linux /out/run-c512.sh T3
docker exec wt-linux /out/run-c512.sh T4
# hono-2/4 controls and hono-2 low-c: inline loops, see session log
```
