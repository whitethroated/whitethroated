# WhiteThroated vs Express.js on Bun vs actix-web — external-contract benchmark report

> Socket-option erratum: historical `tcp_nodelay=off` / override `0` labels did not prove TCP_NODELAY was disabled. The old client skipped its override while NIO enabled TCP_NODELAY by default; its explicit `1` used the wrong option level. See [the correction and validation](benchmark-socket-options-2026-10-18.md). Raw measurements are preserved; rebaseline with verified socket values. This report ran **after** the correction: the client requested and socket-verified `TCP_NODELAY=1` on every run.

Date: 2026-10-22. Machine: Docker container `swift:6.4.0-noble` on an
Apple Silicon host (Linux 7.0.12-linuxkit aarch64 VM, 8 vCPUs, cgroup
`8 CPUs`, 8 GiB memory cap). This is a single-machine loopback diagnostic.

Toolchains: Swift 6.4 RELEASE with SwiftNIO exactly 2.104.0 (pinned); Rust
rustc 1.99.1 + cargo 1.99.1 with actix-web `=4.8.0` (opt-level 3, thin LTO,
codegen-units 1); Bun 1.4.3 with Express `=5.3.0`.
WhiteThroated revision measured: `97eec5ea0fb910a2578bd1f935cdbde919d14fff`
(`main`, clean tree). The Tier-1 HTTP/1 engine with stock fallback is the
default at this HEAD.

Evidence qualification: three rotated rounds per cell on one shared machine;
medians are computed per cell from independent rounds and nothing is pooled.
The numbers are diagnostic evidence for maintenance direction, not a
publication claim. Cross-generation comparison against the 2026-10-17/18
documents is invalid: the load generator and socket-option semantics changed
(corrected client loop distribution, verified `TCP_NODELAY`), and
`BENCHMARKS.md` requires a full rebaseline for such comparisons.

## 1. Verdict

1. **Throughput: actix-web leads WhiteThroated in objective terms, and both
   lead Bun/Express by a wide margin.** With equal worker counts,
   actix-8/express-8 = 1.292x median ratio; actix configurations are placed
   first in 8 of 9 cells (actix-2 in 7, actix-8 in `GET /user/42` at c512),
   and WhiteThroated's `wt-8` wins the remaining cell (`GET /` at c512).
   WhiteThroated beats Bun/Express in
   every cell at both worker counts: wt-8/express-8 median 1.244x
   (min 1.203, max 1.301), wt-2/express-2 median 1.665x (min 1.521,
   max 1.925).
2. **p99 latency: actix (2 workers) is best in 8 of 9 cells**; WhiteThroated
   is the consistent runner-up ahead of Express and the raw SwiftNIO
   control. Oversubscribing 8 workers/loops onto 4 server CPUs
   degrades p99 for every runtime; the 2-worker configuration is the
   strongest tail setting for both actix and WhiteThroated in this rig.
3. **WhiteThroated's Tier-1 engine outperforms the raw SwiftNIO control in
   this rig today**: wt-2/raw-2 = 1.271x median throughput across all 9
   cells, with lower p99 than the control in all nine cells. The historically
   `zero framework overhead` control is not a throughput ceiling at this
   HEAD's default path; treat it as a baseline reference rather than a cap.
4. **Cost profile:** memory and CPU are within small factors for actix
   (13–15 MiB RSS peak, ~2.9–3.0 CPU-seconds per 500k-request sample at 2
   workers) and WhiteThroated (23–24 MiB peak, ~4.3–6.0 CPU-seconds);
   Express-on-Bun needs 192–563 MiB and 6.6–8.6 CPU-seconds for the same
   contract.

## 2. Equal-condition method

- Comparand processes all pinned to CPUs 0–3 and resident simultaneously on
  distinct ports; the load generator pinned to CPUs 4–7 with 4 loops.
- Load generator for every comparand: the repository Swift benchmark client
  (`whitethroated-benchmark-client`), 500,000 requests per sample,
  latency collection enabled on separate samples, `TCP_NODELAY=1` requested
  and socket-verified per run (observed `1` on all 378 runs).
- Same external contract for every framework, verified per instance by
  preflight (exact status line `HTTP/1.1 200 OK`, exact response body,
  content-length):
  - `GET /` → empty 200
  - `GET /user/42` → body exactly `42`
  - `POST /user` → empty 200
- Configurations:
  - `express-2` / `express-8`: Express 5.3.0 on Bun with a `node:cluster`
    workload of 2/8 worker processes (ports 3010/3011)
  - `wt-2` / `wt-8`: `whitethroated-benchmark-server` with
    `WHITETHROATED_THREADS=2/8` (ports 3020/3021)
  - `actix-2` / `actix-8`: actix-web 4.8.0 with 2/8 workers (ports
    3030/3031)
  - `raw-2`: `raw-nio-benchmark-server` with 2 threads (port 3040)
- Cells: 3 contract routes x connections {64, 256, 512}; 3 rounds with
  rotated config order, route order, and connection order. Per
  (round, route, connection, config): one 20,000-request warm-up, then one
  throughput sample and one latency-enabled sample.
- The stream-enabled route `/response-stream-known` is Swift-internal and is
  excluded from this comparison.
- Run integrity: 378/378 measured rows; 7/7 preflights passed; a
  body-bytes-per-request tripwire (root=0, user=2, post=0) matched every
  row; the client aborts on non-200 or dropped connections, which never
  occurred.

## 3. Throughput (median RPS per cell, mode=rps)

| Connections | Route | express-2 | express-8 | wt-2 | wt-8 | actix-2 | actix-8 | raw-2 | best |
|---|---|---|---|---|---|---|---|---|---|
| 64  | `GET /`        | 134.1k | 232.0k | 246.9k | 290.8k | 315.9k | 301.9k | 188.8k | actix-2 |
| 64  | `GET /user/42` | 102.2k | 205.1k | 196.6k | 266.9k | 313.0k | 280.9k | 159.2k | actix-2 |
| 64  | `POST /user`   | 147.0k | 214.1k | 223.7k | 272.2k | 301.7k | 289.0k | 185.9k | actix-2 |
| 256 | `GET /`        | 162.1k | 241.9k | 252.9k | 290.9k | 316.6k | 312.5k | 195.3k | actix-2 |
| 256 | `GET /user/42` | 121.3k | 234.7k | 205.3k | 292.1k | 318.7k | 301.6k | 161.5k | actix-2 |
| 256 | `POST /user`   | 144.7k | 241.1k | 232.0k | 297.2k | 307.9k | 297.1k | 198.4k | actix-2 |
| 512 | `GET /`        | 154.4k | 265.1k | 257.0k | 320.6k | 318.7k | 310.0k | 202.2k | wt-8 |
| 512 | `GET /user/42` | 117.3k | 224.9k | 207.7k | 281.2k | 304.6k | 310.0k | 160.4k | actix-8 |
| 512 | `POST /user`   | 146.7k | 236.3k | 229.4k | 284.1k | 301.7k | 298.2k | 191.5k | actix-2 |

Head-to-head ratios over the 9 cells (per-cell ratio first, then median):

| Aspect | Median | Min–max |
|---|---|---|
| wt-8 / express-8 | 1.244 | 1.203–1.301 |
| wt-8 / actix-8 | 0.953 | 0.907–1.034 |
| wt-2 / express-2 | 1.665 | 1.521–1.925 |
| wt-2 / actix-2 | 0.753 | 0.628–0.806 |
| wt-2 / raw-2 | 1.271 | 1.169–1.308 |
| actix-8 / express-8 | 1.292 | 1.169–1.378 |

## 4. p99 latency (us; medians of per-round percentiles, mode=lat)

| Connections | Route | express-2 | express-8 | wt-2 | wt-8 | actix-2 | actix-8 | raw-2 |
|---|---|---|---|---|---|---|---|---|
| 64  | `GET /`        | 1099.5 | 1692.5 | 509.1 | 827.8 | 428.9 | 521.7 | 681.0 |
| 64  | `GET /user/42` | 1396.2 | 2228.1 | 668.4 | 968.5 | 504.8 | 734.8 | 800.3 |
| 64  | `POST /user`   | 1187.8 | 1899.0 | 589.9 | 953.7 | 604.9 | 602.2 | 702.6 |
| 256 | `GET /`        | 3752.0 | 5283.8 | 2413.7 | 2895.5 | 1591.5 | 1666.0 | 2506.9 |
| 256 | `GET /user/42` | 4042.2 | 6438.6 | 2493.0 | 3709.6 | 1568.5 | 1977.5 | 2907.2 |
| 256 | `POST /user`   | 3550.3 | 6109.8 | 2218.2 | 3754.6 | 1638.0 | 1712.2 | 2562.0 |
| 512 | `GET /`        | 5900.7 | 8985.8 | 3803.0 | 4682.7 | 3010.8 | 3258.4 | 4749.6 |
| 512 | `GET /user/42` | 7642.0 | 9676.4 | 4508.2 | 5844.3 | 2961.6 | 3444.0 | 5025.1 |
| 512 | `POST /user`   | 6593.9 | 9654.4 | 4222.3 | 5089.5 | 3196.7 | 3378.8 | 5205.7 |

p99 winner per cell: actix-2 in 8 of 9 cells; `wt-2` wins `POST /user`
at c64; Express and the raw control win none.

## 5. Server cost (median server CPU-seconds per 500k-request run; peak process-tree RSS)

| Config | CPU-s (c64/c256/c512) | RSS |
|---|---|---|
| express-2 | 6.80 / 6.74 / 6.64 | 191.8 MiB |
| express-8 | 8.64 / 7.78 / 7.88 | 563.0 MiB |
| wt-2 | 4.44 / 4.27 / 4.28 | 23.2 MiB |
| wt-8 | 6.11 / 5.96 / 5.96 | 23.9 MiB |
| actix-2 | 2.92 / 2.94 / 2.98 | 13.3 MiB |
| actix-8 | 4.73 / 4.48 / 4.45 | 14.9 MiB |
| raw-2 | 5.31 / 5.10 / 5.19 | 24.0 MiB |

## 6. Raw SwiftNIO control status

The `raw-2` control was beaten by the WhiteThroated Tier-1 default path in
every throughput cell and on p99 in nearly every cell in this rig. The
Tier-1 promotion-era relation (raw control as an upper bound for the frozen
contract) no longer holds at this HEAD with the corrected client; the raw
control is retained as a baseline reference. Whether the raw bench server
needs rework (worker shape, affinity, or prepared paths) remains an open
investigation item; this report does not attribute a correctness problem to
either server (all preflights passed for both).

## 7. Anomalies and qualification

- `express-8` throughput rounds swing up to 1.43x between rounds within a
  cell (`GET /` c64: 168.6k–241.2k; c256: 191.8k–262.6k). The Bun cluster is
  the noisiest stack in the rig; medians are reported unmodified.
- 8-worker oversubscription consistently hurts p99 (actix-8 vs actix-2,
  wt-8 vs wt-2) under the 4-CPU server allocation.
- No readiness-poll timeout occurred on any server; all preflights passed on
  the first attempt.
- `env.txt` capture note: the first environment snapshot wrote blank
  bun/cargo/rustc version keys because the toolchain PATH was extended after
  the snapshot; those keys were patched with the recorded versions
  (`1.4.3`, `cargo 1.99.1 (5f94df478 2026-08-27)`,
  `rustc 1.99.1 (58cf8f9c3 2026-10-13)`) without touching any measurement
  row.

## 8. Artifacts and provenance

- Measured artifacts (raw TSV, per-run client stdout, preflight headers and
  bodies, analyzer report) live outside the repository under
  `results-xfw-20261022-064631/` on the host, per the runtime performance
  and benchmark-validation skills.
- External framework implementations live outside the repository, per the
  repository's Swift-only source policy: an Express 5.3.0 server script and
  a small actix-web 4.8.0 crate were used for the comparison. Framework
  versions were recorded above; no repository files were modified for this
  campaign.
- Harness behavior: rotating config/route/connection order per round;
  per-cell medians over independent rounds; nothing pooled. The analyzer
  output is archived with the raw data alongside the per-run client logs.
