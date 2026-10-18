# Tier 1 custom HTTP/1 A/B: Raw NIO vs WT stock vs WT custom (2026-10-18)

Historical configuration: stock was the default for this campaign. On current
code, explicitly set `WHITETHROATED_TIER1_HTTP1=0` to reproduce its stock path.
See [the default-transport validation](benchmark-tier1-default-2026-10-18.md)
for the subsequent parser, streaming, and pipelining correctness changes.

## Verdict

**Neutral.** The Tier 1 custom HTTP/1 path (`WTHTTP1ConnectionHandler`,
`WHITETHROATED_TIER1_HTTP1=1`) performs within ordinary run-to-run noise of
the stock NIOHTTP1 pipeline on every measured cell. The measurable
NIOHTTP1-pipeline tax in this environment is approximately **0-2%**, and the
total raw-control lead over the framework is only **~0.5-4%** per cell. This
data does **not** justify Phase 3 (custom socket loop): WhiteThroated already
captures nearly everything available from NIO here.

## Setup

- Machine: Apple M1 Pro, 8 cores, macOS (co-located loopback).
- Swift 6.2.4, SwiftNIO 2.104.0 (pinned), release builds.
- Servers (all `WHITETHROATED_THREADS=2`, HTTP/1.1 keep-alive):
  - `raw` — `raw-nio-benchmark-server` (port 3010).
  - `stock` — `whitethroated-benchmark-server` (port 3011).
  - `tier1` — same binary + `WHITETHROATED_TIER1_HTTP1=1` (port 3012).
- Load generator: `whitethroated-benchmark-client`, one generator for all
  cells, 500,000 requests per cell, separate throughput (R) and latency (L)
  runs per cell.
- Matrix: 3 routes (`GET /`, `GET /user/42`, `POST /user`) x 3 concurrency
  levels (c64/c256/c512) x 4 rounds (R1 raw-first, R2 tier1-first, R3
  raw-first, R4 tier1-first). Interleaved per cell for drift control.
- Raw logs: `/tmp/wt-tier1-ab/` (216 logs: R1-R4 x R/L x 27 cells).
- Correctness at load: echo bodies verified byte-count-correct on all three
  servers (500k x "42" = 1,000,000 bytes); no client errors in any cell.

## Results (mean of 4 rounds)

RPS (higher is better):

| route    | c   | raw    | stock  | tier1  | tier1 vs stock |
|----------|-----|--------|--------|--------|----------------|
| root     | 64  | 146148 | 137205 | 140654 | +2.5%          |
| root     | 256 | 140913 | 143852 | 144117 | +0.2%          |
| root     | 512 | 144666 | 140360 | 142683 | +1.7%          |
| user-get | 64  | 131938 | 128389 | 128065 | -0.3%          |
| user-get | 256 | 131383 | 116222 | 126230 | +8.6% (*)      |
| user-get | 512 | 130512 | 127551 | 126745 | -0.6%          |
| user-post| 64  | 138493 | 138181 | 137720 | -0.3%          |
| user-post| 256 | 140442 | 133892 | 135402 | +1.1%          |
| user-post| 512 | 137533 | 138186 | 136360 | -1.3%          |

(*) One stock round collapsed to 78k RPS (R4; other rounds 128-130k). Excluding
that single outlier, stock means ~128.9k and the cell reads tier1 -2.1%: still
inside the observed round-to-round spread.

Latency means (us; avg / p50 / p90 / p99):

| route/c   | raw                        | stock                      | tier1                      |
|-----------|----------------------------|----------------------------|----------------------------|
| root/64   | 434/386/700/870            | 455/399/727/982            | 444/395/714/909            |
| root/256  | 1760/1689/2036/3528        | 1745/1697/1911/3434        | 1752/1696/1915/3446        |
| root/512  | 3457/3417/3702/6745        | 3647/3534/4031/6678        | 3500/3468/3743/6693        |
| uget/64   | 482/434/773/980            | 494/445/786/1008           | 491/443/784/997            |
| uget/256  | 1924/1863/2123/3865        | 2011/1911/2379/4334 (*)    | 1947/1906/2134/3827        |
| uget/512  | 3845/3807/4056/5749        | 3947/3904/4168/5676        | 3997/3910/4327/6879 (**)   |
| upost/64  | 447/395/711/910            | 459/408/736/936            | 459/407/734/934            |
| upost/256 | 1770/1695/2026/3535        | 1899/1777/2353/4144        | 1842/1758/2134/3717        |
| upost/512 | 3616/3512/4004/7132        | 3637/3575/3908/7091        | 3619/3562/3903/7103        |

(**) Tier 1 p99 mean is inflated by one noisy round (R1 8793us vs 4790us in
R2); round spreads on p99 reach +-40% in this saturated-loopback setup, so no
tail conclusion is drawn in either direction. No systematic tail regression
for Tier 1 was observed.

## Noise assessment

Within-server round-to-round spreads routinely exceed the stock-vs-tier1
deltas, e.g. stock root-c64 RPS across rounds: 137.5k/141.3k/138.6k/131.4k
(7% range); tier1 root-c64: 131.3k/143.2k/144.2k/143.9k (9% range). Per the
acceptance checklist, results inside ordinary run-to-run noise are called
neutral, not faster. Two cells looked decisive at 2 rounds (root-c512 +5% win,
user-get-c256 -4% deficit) and both regressed toward neutral at 4 rounds.

## Interpretation

1. **The NIOHTTP1 pipeline tax is ~0-2% here, not 10-20%.** Bypassing the
   decoder, pipelining handler, error handler, and encoder moves throughput
   within noise. The conversion tax at the Tier 1 boundary (one NIO request
   head + response header Strings per request) likely cancels part of the
   pipeline savings; a conversion-free Tier 1b (dispatcher speaking WT types)
   would be needed to measure the true ceiling, at the cost of framework
   changes.
2. **The total raw-control lead is small (~0.5-4%, mean ~2.5%).** The raw
   server leads 7/9 cells but loses 2 outright (root-c256, user-post-c512),
   which shows how saturated this environment is: loopback, client, and
   event-loop contention dominate, and all three servers sit in the same
   band. Even perfect elimination of framework+NIOHTTP1 overhead gains at
   most a few percent here.
3. **No tail-latency signal either way.** Tier 1 p50/p90/p99 track stock
   within the (large) p99 noise; the p90/p99 gaps vs Hono observed earlier
   are not explained by NIOHTTP1 framing work.
4. **Phase 3 is not justified by this evidence.** A custom socket loop would
   chase, at best, the ~2.5% raw gap in this environment, at high correctness
   risk. Recommendation: keep NIO as the I/O substrate.

## Caveats

- Co-located saturated loopback on macOS with 2 server threads is one point
  in the space, chosen as the previously measured optimum for this setup. A
  Linux re-test with more cores and a real network could change magnitudes;
  the neutral direction (small tax) is expected to hold but is unverified
  there.
- One stock collapse round (78k RPS) and one noisy tier1 p99 round were
  observed; single samples, reported as observations only, excluded from no
  means except where noted.

## Reproduction

```sh
swift build -c release --product whitethroated-benchmark-server \
  --product raw-nio-benchmark-server --product whitethroated-benchmark-client
ulimit -n 10240
WHITETHROATED_PORT=3010 WHITETHROATED_THREADS=2 .build/release/raw-nio-benchmark-server &
WHITETHROATED_PORT=3011 WHITETHROATED_THREADS=2 .build/release/whitethroated-benchmark-server &
WHITETHROATED_PORT=3012 WHITETHROATED_THREADS=2 WHITETHROATED_TIER1_HTTP1=1 \
  .build/release/whitethroated-benchmark-server &
/tmp/wt-tier1-ab/run-route-r1.sh root GET /
# ... etc for user-get, user-post, rounds R1-R4 (scripts in /tmp/wt-tier1-ab/)
```

Note: `ulimit -n 10240` is required on both servers and client for c256/c512;
the default 256 fd limit fails those cells with client-side traps.
