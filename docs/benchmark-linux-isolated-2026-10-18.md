# Linux isolated-CPU verdict: WhiteThroated vs Express/Hono on Bun (2026-10-18)

> Superseded by `docs/benchmark-tier1-linux-verdict-2026-10-18.md` for the
> overall campaign verdict (Tier-1 engine: 54/54 cells, all 8 aspects).
> This document remains the stock-engine record (52/54 cells, one
> exception cell) and the methodology reference for the isolated rig.

## Verdict

Under the fairest setup achieved in this project — Linux, Bun cluster with
all 8 workers genuinely serving, and load generator pinned to separate CPUs
from the servers — **WhiteThroated leads all 8 aspects**:

| Aspek        | Winner (isolated Linux)                              |
|--------------|------------------------------------------------------|
| Throughput   | WT-2, 9/9 cells                                      |
| Average      | WT-2, 9/9 cells                                      |
| p50          | WT-2, 9/9 cells                                      |
| p75          | WT-2, 9/9 cells                                      |
| p90          | WhiteThroated 9/9 (WT-2 7/9, WT-4 2/9)               |
| p99          | WhiteThroated 8/9 (WT-2 5/9, WT-4 2/9, WT-8 1/9)      |
| Konsistensi  | WhiteThroated 8/9 (WT-2 5/9, WT-4 2/9, WT-1 1/9)      |
| Raw speed    | WT-2 (peak 212k RPS vs Hono 162k)                    |

The single exception cell is `GET /user/42` at c512, where Hono-8 takes p99
(3.8ms vs WT-2 5.0ms) and consistency (1.11 vs 1.89), replicated across 4
rounds. Every other metric-cell (52/54) is WhiteThroated. Express wins
nothing anywhere.

## Why this setup is the fair one

1. **macOS Bun cluster is degenerate.** Proven twice via connection counts:
   256/256 connections land on ONE of 8 Bun workers on macOS, so "Hono-8"
   there is really Hono-1. That accident gave Hono artificially smooth tails
   (single-worker queueing) while capping its throughput.
2. **Linux Bun cluster is genuine.** Per-worker CPU times after the matrix:
   8x ~36s each for Hono, 8x ~43-45s each for Express. Even spread.
3. **CPU isolation removes the co-location confound.** Servers pinned to CPUs
   0-3, load generator (4 threads) pinned to CPUs 4-7, all inside one Linux
   container. Without isolation, server threads and client threads fight for
   the same cores and tails measure scheduling luck as much as server quality.

## Setup

- Host: Apple M1 Pro 8-core; Docker Desktop Linux VM (aarch64), 8 vCPUs.
- Container: `swift:6.4.0-noble` (same image as CI), repo mounted at /work.
- Swift 6.4 RELEASE, SwiftNIO 2.104.0 (pinned), release builds.
- Bun 1.4.3+c6da4a4d3 (Rust line) in-container — same revision as macOS runs.
  Express 5.3.0, Hono 4.13.13 (fresh Linux `bun install`).
- Servers: express-8 (:3010), hono-8 (:3011), wt1 (:3013), wt2 (:3012),
  wt8 (:3014); wt4 (:3015) added for anchor rounds. All server processes
  pinned to CPUs 0-3.
- Load generator: same Swift benchmark client, 500k requests/cell, pinned to
  CPUs 4-7 with 4 threads.
- Contract: identical 3 routes (`GET /`, `GET /user/:id`, `POST /user`),
  HTTP/1.1 keep-alive, c64/c256/c512, rounds I1 (forward) + I2 (reversed),
  plus anchor rounds I3/I4 (hono/wt2/wt4 only) for the WT-4 question.
- Deviation from macOS runs (documented, equal for all servers): client
  `TCP_NODELAY=0`, because Docker Desktop's VM denies `setsockopt`
  TCP_NODELAY (EPERM). Absolute numbers are not comparable across platforms;
  rankings within a platform are.
- Raw logs: `/tmp/wt-linux/` (180 I1/I2 logs + 108 I3/I4 logs).

## Results (isolated, mean of I1/I2; anchor cells confirmed by I3/I4)

Format per cell: rps / avg / p50 / p75 / p90 / p99 (us) — bold = best.

Root `GET /`:

| c   | express              | hono                 | wt1                  | wt2                       | wt8                  |
|-----|----------------------|----------------------|----------------------|---------------------------|----------------------|
| 64  | 172k/364/325/373/600/815  | 162k/388/362/399/477/805  | 119k/515/490/542/623/1045 | **205k/306/287/332/389/626** | 175k/355/327/365/557/740 |
| 256 | 173k/1445/1419/1511/1594/2995 | 162k/1555/1550/1655/1741/2872 | 116k/2182/2114/2195/2506/4074 | **209k/1194/1174/1306/1398/2147** | 180k/1388/1377/1496/1595/2756 |
| 512 | 175k/2844/2844/3004/3095/5631 | 153k/3296/3304/3414/3507/3760 | 114k/4469/4407/4519/4721/5591 | **209k/2394/2416/2607/2789**/4329 | 177k/2839/2849/2990/3121/**3492** |

User-get `GET /user/42`:

| c   | express              | hono                 | wt1                  | wt2                       | wt8                  |
|-----|----------------------|----------------------|----------------------|---------------------------|----------------------|
| 64  | 172k/362/311/418/609/907  | 156k/404/377/413/485/835  | 96k/638/620/675/742/1295 | **192k/315/305/357/470/642** | 173k/362/328/369/586/741 |
| 256 | 178k/1395/1286/1450/2113/2989 | 158k/1593/1589/1670/1745/3034 | 96k/2651/2594/2686/2947/3612 | **188k/1319/1276/1431**/1712/**2576** | 175k/1411/1412/1488/**1559**/2883 |
| 512 | 173k/2882/2787/3033/3166/6021 | 150k/3368/3381/3496/3597/**3895** | 91k/5611/5530/5639/5877/6827 | **194k/2544/2387/2959**/3570/4717 | 177k/2805/2816/2957/**3061**/5230 |

User-post `POST /user`:

| c   | express              | hono                 | wt1                  | wt2                       | wt8                  |
|-----|----------------------|----------------------|----------------------|---------------------------|----------------------|
| 64  | 159k/392/350/399/655/901  | 150k/418/392/427/490/864  | 115k/534/513/548/621/1086 | **189k/331/310/356/419/676** | 161k/385/355/390/607/788 |
| 256 | 162k/1549/1518/1607/1692/3204 | 147k/1705/1708/1781/1848/3132 | 106k/2380/2326/2410/2626/3205 | **192k/1310/1261/1421/1516/2581** | 162k/1533/1529/1617/1700/3021 |
| 512 | 156k/3214/3228/3353/3450/6247 | 144k/3532/3539/3649/3745/3934 | 104k/4897/4761/5058/5374/6012 | **193k/2577/2558/2813/3263**/4871 | 150k/3344/3357/3463/3552/**3729** |

Consistency (p99/mean, lower is better):

| route/c       | express | hono     | wt1      | wt2      | wt8      |
|---------------|---------|----------|----------|----------|----------|
| root/64       | 2.24    | 2.08     | **2.03** | 2.05     | 2.08     |
| root/256      | 2.07    | 1.85     | 1.87     | **1.80** | 1.99     |
| root/512      | 1.98    | 1.14 (*) | 1.25     | 1.81     | 1.23     |
| uget/64       | 2.51    | 2.07     | **2.03** | 2.04     | 2.05     |
| uget/256      | 2.14    | 1.90     | **1.36** | 2.46     | 2.04     |
| uget/512      | 2.09    | **1.16** | 1.22     | 1.85     | 1.86     |
| upost/64      | 2.30    | 2.07     | **2.03** | 2.04     | 2.04     |
| upost/256     | 2.07    | 1.84     | 1.35     | **1.81** | 1.97     |
| upost/512     | 1.94    | 1.11 (*) | 1.23     | 1.89     | 1.12     |

(*) Anchor rounds I3/I4 re-tested these cells with WT-4 added: WT-4 takes
root-c512 consistency (1.14, tie-break over Hono 1.29 that round) and
user-post-c512 consistency (1.11 vs Hono 1.16), plus p99 on both cells. Only
user-get-c512 stays Hono on p99 (3.8ms vs 5.0ms) and consistency (1.11 vs
1.89), replicated in all 4 isolated rounds (I1-I4).

## Interpretation

1. **Parallelism trades throughput for tails, on every implementation.**
   Fewer workers = smoother tails + lower throughput (wt1/wt2 ratios
   ~1.1-2.1); more workers = higher throughput + ragged tails. Hono-1 on
   macOS (ratios ~1.2) vs Hono-8 on Linux (ratios up to 5.8 unisolated)
   proves the mechanism is worker count, not framework magic. Hono's macOS
   tail win was an accident of degenerate single-worker accept.
2. **With CPUs isolated, WT-2 is the best-balanced configuration measured:**
   highest throughput on every cell while keeping tails at or near the best.
   WT-4 improves the two c512 tail cells it was tried on.
3. **The residual gap is one high-concurrency dynamic-route cell**
   (user-get c512: param extraction + per-request text response at 512
   connections). WT-2's mean there is far better (2.6ms vs 3.4ms) but its
   tail stretches further. Suspected per-request allocation pressure under
   512-connection saturation; WT-4 did not fix this cell (5.3ms p99).
4. **Unisolated Linux (R1/R2) told the same story directionally** (Hono-8
   took RPS/avg/p50/p90 there because 8 workers grab more of the shared
   cores; WT-2 took p99/consistency), but co-location makes that ranking a
   scheduling artifact. Isolated data supersedes it.
5. **Tier-1 custom HTTP/1 was neutral** (see
   `docs/benchmark-wt-tier1-http1-2026-10-18.md`): the NIOHTTP1 pipeline tax
   is ~0-2%, so these results reflect framework + runtime fundamentals, not
   framing overhead.

## Caveats

- Docker Desktop VM adds a virtualization layer; absolute numbers are
  VM-specific, but all servers share it equally and round-to-round stability
  was excellent (typically +-2-5%).
- Client `TCP_NODELAY=0` (VM denies the sockopt) — equal for all servers.
- `/tmp/js-bench` node_modules were refreshed with a Linux `bun install`
  (pure-JS deps; harmless outside the repo).
- Bare-metal Linux with a separate load-generator machine remains the gold
  standard and could still move the single exception cell either way.

## Reproduction

```sh
docker run -d --name wt-linux --cpus=8 --memory=8g \
  -v "$PWD":/work -v /tmp/wt-linux:/out -v /tmp/js-bench:/jsbench \
  -w /work swift:6.4.0-noble sleep infinity
docker exec wt-linux bash -c "apt-get update -qq && apt-get install -y -qq curl unzip"
docker exec wt-linux bash -c "curl -fsSL https://bun.sh/install | bash"
docker exec wt-linux bash -c "export PATH=\$HOME/.bun/bin:\$PATH; \
  cd /jsbench/hono-bench && bun install; cd /jsbench/express-bench && bun install"
docker exec wt-linux swift build -c release \
  --product whitethroated-benchmark-server --product whitethroated-benchmark-client
# start servers pinned to 0-3 (see /tmp/wt-linux commands), then:
docker exec wt-linux /out/run-iso.sh I1
docker exec wt-linux /out/run-iso.sh I2
```
