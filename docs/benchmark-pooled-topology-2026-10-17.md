# Pooled topology baseline — diagnostic, not a Pareto win

Date: 2026-10-17. Verdict **C: variance prevents accepting a topology
optimization from this campaign**. No production optimization was made.
The broader competitor objective remains unmet: existing macOS comparisons show
WhiteThroated ahead in throughput/central latency but behind Hono on Bun at
p90/p99; Express on Bun also wins p99 in the recorded base and small-JSON matrices.

## What changed

The client now optionally exports raw nanosecond samples and configuration.
A Swift-only offline merger computes pooled percentiles and wall-window RPS.
It rejects missing/duplicate/incompatible/incomplete shards. This fixes an
apparatus limitation: averaging shard percentiles does not yield a pooled tail.
Historical reports retain their original statistics; these are fresh baselines.
There is no framework, runtime, response-semantic or public-API change.

Hypothesis: the previously observed topology tail benefit should be measurable
with pooled quantiles under the same total client/server loops, without a p50
regression. This campaign does **not** establish that Pareto improvement.

## Environment and contract

- Apple M1 Pro, 8 physical/logical cores, 16 GiB RAM, macOS 26.6.2 (25G83).
- Apple Swift 6.2.4 / swiftlang-6.2.4.1.4; **not the requested Swift 6.4**.
- SwiftNIO exactly 2.104.0; release configuration, no extra compiler flags.
- HEAD `389f534d14640014fd70361a7f4b0e800570a174` remained unchanged;
  uncommitted benchmark export/merge changes used for all cells.
- Framework `GET /`: empty 200, HTTP/1.1, Host-only request, TCP_NODELAY,
  keep-alive, one outstanding request per connection. No new competitor run.
- Four server topologies: 1×8, 2×4, 4×2, 8×1, explicit ports 3210 onward;
  shard i maps to port 3210 + i % workerCount.
- Eight concurrent clients, each 32 connections, 125000 requests and **one
  event-loop thread**: total 256 connections and 1000000 requests per cell.
  This differs from historical campaigns using default client thread counts;
  do not directly compare absolute values with those campaigns.
- Three rounds; order forward/reverse/forward; throughput off then latency on
  per topology. Per-worker warmup: 10000 requests, 8 connections, one thread,
  before each topology-round. Workers restart between topology-rounds.
- RPS below is median of three throughput-only runs. Each latency column is
  median of three independently pooled latency runs; not one synthetic joint run.
- First response per connection excluded from latency, retained for RPS:
  999744 samples per latency cell. All 192 shards completed; 24 million total
  requests, no observed status/connection failures or count shortfalls.
- Same-host monotonic measurement window includes shard launch skew:
  12.50–63.83 ms, median 23.36 ms. No barrier synchronization was used.

## Results

Latency units: microseconds. RPS: requests/second.

| Topology | RPS | Average | p50 | p75 | p90 | p99 | Maximum |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1×8 | 144175 | 1772 | 617 | 1879 | 4210 | 18113 | 75011 |
| 2×4 | 145901 | 1752 | 702 | 1904 | 4111 | 15472 | 60722 |
| 4×2 | 148651 | 1731 | 768 | 1923 | 3996 | 13568 | 99233 |
| 8×1 | 143174 | 1769 | 910 | 1960 | 3914 | 12392 | 65778 |

Per-round throughput (forward chronological round number):

| Topology | Round 1 | Round 2 | Round 3 |
|---|---:|---:|---:|
| 1×8 | 141513 | 144175 | 144764 |
| 2×4 | 127865 | 146468 | 145901 |
| 4×2 | 123963 | 148869 | 148651 |
| 8×1 | 143174 | 147566 | 83459 |

Per-round pooled p99:

| Topology | Round 1 | Round 2 | Round 3 |
|---|---:|---:|---:|
| 1×8 | 19224 | 15919 | 18113 |
| 2×4 | 16986 | 14512 | 15472 |
| 4×2 | 19898 | 13568 | 12676 |
| 8×1 | 12392 | 11490 | 18805 |

## Acceptance and limits

Nominal median 4×2 versus 1×8: RPS +3.1%, p90 −5.1%, p99 −25.1%,
**p50 +24.5%**. For 8×1: RPS −0.7%, p90 −7.0%, p99 −31.6%,
**p50 +47.4%**. These are descriptive ratios, not accepted improvement claims.
Every multi-process topology has worse p50 than 1×8 in each paired round;
none passes the required +3% p50 gate in this apparatus. Do not recommend
4×2 or 8×1 as an all-metric improvement on this evidence.

Round spreads are large: 8×1 throughput falls from 147566 to 83459 in round 3;
4×2 p99 ranges from 12676 to 19898. Median tails favor process separation,
but the host cannot resolve a stable Pareto gain here. Three rounds also do not
satisfy the strengthened five-round gate for sub-10% effects.

Pre-flight load was approximately 3.25 (8 cores), later 4.64; system free-memory
percentage was 46–47%. A spot observation showed WindowServer ~43% CPU, Chrome
renderer ~32%, VS Code renderer ~24%, and Codex renderer ~16%, alongside benchmark
processes. No user processes were changed. An up-to-date release-test invocation
overlapped the early campaign; its passing result does not make this an isolated
publication run. These confounders are retained, not silently filtered. No
causal attribution of individual outliers is justified.

Server idle/post/peak RSS, CPU deltas, switches and migrations were **not collected
in this campaign**. Existing topology memory/scheduler reports remain separate
evidence; do not join their values into this new table. No Linux conclusions,
cache-causality claim or fresh competitor ranking follows from this run.

## Reproduction and next evidence

Build the client, merge tool and benchmark server in release mode. Follow the
complete single-cell example in `linux-validation-checklist.md` on macOS too,
substituting ports 3210 onward and the parameters above. Run the specified three
orders, and keep all eight shard outputs for each cell. Merge with expected
shard count 8. Successful files carry schema 1, run IDs, sample IDs and raw
monotonic timestamps. The checked-in [per-cell summaries](benchmark-data/pooled-topology-2026-10-17.json)
include every measured throughput and latency cell, without removing outliers.
Raw client outputs and logs are retained at `/tmp/whitethroated-pooled-20261017/`;
local orchestration source is `/tmp/whitethroated-pooled-campaign.swift`.
Temporary raw files must be archived externally before any publication.

Next macOS adjudication requires a quiet, compilation-free five-round window,
the same eight-client apparatus, c64/c256/c512 and the three contract routes,
plus per-worker CPU/RSS. Include raw/runtime/framework and competitor controls
before interpreting a pooled competitor gap. Do not rerun blindly on this noisy
window or reopen the closed allocator/receive-buffer/QoS experiments.

The narrowest layer currently supported by prior controls/profiles is the shared
SwiftNIO HTTP/pipeline/write/event-loop and kernel execution path, below the
framework/runtime bridge. This campaign identifies no specific hard transport
ceiling. Context-switch counts do not establish scheduling-delay causality, and
cache causality remains unmeasured. Controlled Linux topology transfer, accept
distribution and scheduler/cache counters remain pending under the checklist.
A replacement transport is not justified.

## Verification

Release suite: 370 tests executed, 4 existing skips, zero failures. This includes
four new deterministic aggregation tests covering pooled quantiles, whole-window
RPS, singleton/throughput-only cases, round-trip sample preservation, duplicate,
incompatible, incomplete and invalid-timing inputs. Release products built
successfully during validation. CLI smoke: valid single-shard input succeeds;
a missing-shard invocation exits 1 without producing a summary. Network export
and pooling exercised in all 24 cells. No non-Swift implementation source or
production dependency was added; no commit was created.
