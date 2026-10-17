# Matched small-JSON matrix: WhiteThroated vs Hono/Bun vs Express/Bun

Date: 2026-10-17. Host: Apple M1 Pro, macOS, 8 cores.
Swift 6.2.4, SwiftNIO 2.104.0, Bun 1.4.3, Hono 4.13.13, Express 5.3.0.
Repo at `5c55d17` plus uncommitted benchmark-only `/json` additions
(raw-NIO + runtime servers) and `/tmp`-only Bun route additions.

## Contract

`GET /json` → `200`, `content-type: application/json; charset=utf-8`,
`content-length: 27`, body `{"message":"Hello, World!"}` (27 bytes).
HTTP/1.1 keep-alive, closed-loop, 1M requests/cell, `ulimit -n 10240`,
100k warmup per server per round, RPS = median of 3 interleaved rounds,
latency = mean of 2 interleaved rounds (µs). Swift servers: default 8
event loops. Bun servers: `BENCH_WORKERS=8` cluster. Same Swift client,
default 8 threads, for all five servers. All 75 cells completed exactly
1,000,000 requests (zero shortfalls/errors).

Byte verification (`curl -i`, all five servers): status, content-type,
content-length, and body bytes identical. The three Swift servers emit
exactly those bytes; Bun adds a `Date` header on both stacks, and
Express additionally sends `Connection: keep-alive` / `Keep-Alive:
timeout=5`. Same natural-output methodology as the base-route matrix.

## Results

RPS = median of 3; avg/p50/p75/p90/p99/max = mean of 2 (µs).

| server    | conn | RPS    | avg  | p50  | p75  | p90  | p99   | max   |
|-----------|------|--------|------|------|------|------|-------|-------|
| raw       | 64   | 138225 | 463  | 338  | 523  | 822  | 2486  | 36265 |
| runtime   | 64   | 135307 | 503  | 340  | 557  | 927  | 2886  | 70284 |
| framework | 64   | 132501 | 470  | 319  | 527  | 900  | 2669  | 18887 |
| hono      | 64   | 92807  | 649  | 612  | 650  | 733  | 1291  | 22760 |
| express   | 64   | 70493  | 843  | 808  | 861  | 975  | 1680  | 3581  |
| raw       | 256  | 142924 | 1809 | 1321 | 2115 | 3305 | 8216  | 48217 |
| runtime   | 256  | 136462 | 1829 | 1297 | 2130 | 3422 | 8778  | 47862 |
| framework | 256  | 130368 | 1912 | 1377 | 2275 | 3645 | 8753  | 67047 |
| hono      | 256  | 96528  | 2641 | 2588 | 2670 | 2801 | 3974  | 34894 |
| express   | 256  | 68898  | 3470 | 3404 | 3548 | 3832 | 4122  | 8086  |
| raw       | 512  | 139345 | 3596 | 2891 | 4375 | 6386 | 12388 | 40129 |
| runtime   | 512  | 137388 | 3621 | 2792 | 4372 | 6649 | 13872 | 53852 |
| framework | 512  | 126927 | 3763 | 2934 | 4642 | 7082  | 13775 | 55854 |
| hono      | 512  | 93739  | 5314 | 5265 | 5414 | 5601 | 6092  | 24044 |
| express   | 512  | 66956  | 7185 | 7129 | 7446 | 7778 | 8449  | 15428 |

Framework vs Hono: RPS +43/+35/+35%, avg −28/−28/−29%,
p50 −48/−47/−44%, p75 −19/−15/−14%, p90 +23/+30/+27%,
p99 +107/+120/+126%. Framework beats Express on RPS, average,
p50, p75 and p90 in every cell (RPS +88/+89/+90%), but loses p99
in all three cells (2669/8753/13775 µs versus 1680/4122/8449 µs).
Express also has the lower maximum in each recorded cell.

## Verdict: B

Same shape as the base-route matrix. WhiteThroated wins throughput,
average, p50, and p75 against both competitors at all three concurrency
levels; Hono wins p90/p99 against WhiteThroated at all three levels
by margins of 23–126%. Express loses throughput and central latency
but also beats WhiteThroated at p99. The empty-body and 27-byte JSON
routes show the same tail pattern, consistent with a substantial cost
below the framework layer; these workloads do not establish behavior
for every REST workload. Latency has only two rounds, so further
replication is required by the current publication gate.

## New observation: tail-variance gap

Hono's run-to-run percentile spread is ±0.4–4% (c512 p50 5244/5286,
p90 5675/5527, p99 6334/5850). Swift-side spreads are typically
±4–15% (runtime c64 p90 1064/791; framework c512 p50 3139/2729).
Hono is not only lower-tailed but far more consistent; Swift/NIO
tails vary run to run. This variance gap supports scheduler /
preemption variance as the leading hypothesis and sharpens the Linux
experiment: correlate p99 with involuntary switches and migrations.

## Open question: Swift-internal /json RPS deficit

Framework-vs-raw RPS is 95.9/91.2/91.1% (runtime-vs-raw 97.9/95.5/
98.6%), below the base-route gate band (97.5–100.3%). Framework beats
raw in only 1 of 9 rounds, runtime in 2 of 9 — too systematic to
dismiss, though c512 ranges overlap (framework R3 138327 sits inside
runtime's 134997–143212) and round 2 shows a correlated
runtime+framework dip (machine event). Ruled out by reading (not
speculation): the JSON head-cache-miss hypothesis is dead — the
27-byte body hits the 0–64 cached-head range and takes the canonical
fast path. Remaining candidates: per-request body-buffer handling on
non-empty responses (raw reuses one shared buffer), Response→runtime
conversion cost. Prescribed isolation before concluding anything:
matched `/prepared` (13-byte prepared body, all three Swift servers
already serve it) vs framework `/plaintext` (same bytes, dynamic)
vs `/` (empty). One variable at a time; do not tune blindly.

## Method appendix

Servers: `.build/release/{raw-nio,whitethroated-runtime,whitethroated}-benchmark-server`
with `WHITETHROATED_PORT=3000`; Bun via `~/.bun/bin/bun
/tmp/js-bench/{hono,express}-bench/server.js` with `BENCH_PORT=3000
BENCH_WORKERS=8`. Client: `.build/release/whitethroated-benchmark-client`
with `WHITETHROATED_BENCH_{METHOD=GET,PATH=/json,CONNECTIONS,REQUESTS=1000000,LATENCY}`.
Orchestrated by `/tmp/json-matrix/run.sh` (smoke-validated before the
full run; raw logs in `/tmp/json-matrix/*.log`, not in the repo).
Round order per round: raw → runtime → framework → hono → express.
