# Header byte-view experiment — 2026-10-19

**Rejected; runtime candidate withdrawn.** Local and native throughput gains
failed to establish the required tail-latency gate. The completed primary and
longer confirmation campaigns contain 612 samples and 360 million measured
requests. Large stalls affect both binaries, so causal attribution remains
uncertain. The full framework performance goal is not achieved.

## One cost center

The [validated CPU profile](benchmark-cpu-symbol-validation-2026-10-19.md) exposed
request-head byte-array materialization. The rejected candidate added package-scoped
read-only header-name/value ByteBuffer views and uses them only for runtime
String decoding. Existing owned-array accessors, URI cache keys, route lookup,
parser/framing, writer and dispatcher behavior remain unchanged. The shared
private range helper preserves the same reader/writer index operations.
No unsafe ownership, inlining attribute, Task, future, lock or dependency was
added by the runtime change. It does not reintroduce prepared-head deferral.

ByteBuffer COW keeps a view's snapshot valid if its original head is mutated.
Runtime consumes each view immediately into an owned String; it does not store
views in a connection cache. The public array accessors still return owned
arrays. The new members are package-scoped; application API/README usage is
unchanged. The runtime candidate and package API are now withdrawn. Exact candidate-only
correctness/codec test sources are archived in the JSON; all passed before
withdrawal. Wire-equivalence coverage and the richer-header pipeline fixture
remain in the repository. The two runtime files match the corrected baseline
source hashes exactly. Socket-option fixes are preserved.

Baseline binaries already include the corrected four-loop generator and TCP
socket-option fix. They are not plain `31f3be6` production binaries: source
fingerprints capture that worktree state. The candidate runtime diff is only
WTHTTP1Types header views plus the two conversion call sites. Before/after
snapshots, source/driver hashes and the exact diff are in the
[machine-readable record](benchmark-data/header-views-2026-10-19.json).

## Correctness and release gate

A new wire-equivalence test passed on baseline before editing the runtime:
header order, case, duplicates, empty/Unicode values, and refreshed values after
cache hits. Five new view tests cover parsed fields, UTF-8 repair equivalence,
nonzero offsets, empty/1/64/4096/16384-byte ranges, COW after head/owned-array
mutation, surviving the head scope, and pipelined input reuse. All 68 equivalence
tests and the new view tests passed on candidate.

Full Swift 6.4/Linux release validation passed 456 XCTest tests (9 diagnostics
skipped), 107 Swift Testing tests, zero failures. All five release products built:
example, framework server, raw NIO server, client and runtime server.
No timing threshold was added to a correctness test.

## Local diagnostics

The opt-in codec diagnostic compares owned arrays versus views in the same
binary, constructing the same NIO HTTPHeaders/Strings from three parsed headers.
It warms both variants and alternates six rounds of 100,000 iterations. Both
checksums match. Median arrays: 426.7 ns; views: 306.8 ns, about 28% lower local
cost. This does not measure end-to-end throughput or allocation counts.

The installed stock/Tier 1 pipeline diagnostic also runs six alternating rounds
per phase with 100,000 requests/round, and checks wire bytes before timing.
A setup-only environment setting adds 0 or 8 Unicode-valued diagnostic headers.
Tier 1 medians (ns/request):

| Extra headers | Responder | Before | Candidate | Change |
| --- | --- | ---: | ---: | ---: |
| 0 | prepared | 1,427 | 1,297 | -9.1% |
| 0 | sync | 1,811 | 1,681 | -7.2% |
| 0 | canonical | 1,884 | 1,763 | -6.4% |
| 0 | stream | 4,062 | 3,896 | -4.1% |
| 8 | prepared | 2,987 | 2,517 | -15.7% |
| 8 | sync | 3,393 | 2,899 | -14.6% |
| 8 | canonical | 3,472 | 2,979 | -14.2% |
| 8 | stream | 5,458 | 4,925 | -9.8% |

Stock controls and every round remain in the JSON. Before/after diagnostics are
separate phases around the build; drift is not eliminated by alternating
stock/Tier 1 within each phase. A local reduction is insufficient for acceptance.

## Completed native A/B

The completed native campaign contains **576 validated samples and 288 million
measured requests**: four rounds, three routes (GET `/`, GET `/user/42`, POST
`/user`), 64/256/512 connections, 0/8 extra request headers, before/after Tier 1
plus stock/raw NIO, and separate throughput-only/latency-enabled phases. Each
cell has 50,000 warm-up and 500,000 measured requests. Server, workload, route
and concurrency order reverse between rounds. All expected counts, body-byte
counts, socket settings, actual loop counts and process exit statuses passed.

One frozen external **Swift** diagnostic client binary is used for every mode
and both workloads. It copies the corrected client and existing BenchmarkResults
module, adding only setup-time extra-header selection and a post-timer marker.
All local dependency checkouts match the pinned Package.resolved revisions;
no new dependency or source was added to the repository for this external driver.
The production benchmark client remains unchanged by this experiment. POST uses
the NIO encoder's chunked request framing, not Content-Length: 0.

Native binaries, logs and counter output are on container-local overlayfs during
measurement, and copied to the host archive only afterward. All modes share that
setup; historical bind-mounted timing is not pooled into this campaign. Client
actual TCP_NODELAY=1 and four loops are checked on every run; servers use two
loops on guest CPUs 0–3 and client CPUs 4–7. There is no profiler preload or
profiling-library path. Preflight exact response-header/body comparisons and
all route/workload/control smoke cases passed.

Four-round medians below. RPS change comes from throughput-only runs; latency
comes from separate latency-enabled runs (microseconds). These are measurements
of this VM and driver, not a universal ranking.

| Extra headers | Route | Connections | RPS change | p99 before → after, µs | p99.999 before → after, µs |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | GET / | 64 | +1.9% | 536 → 494 | 2,156 → 3,485 |
| 0 | GET / | 256 | +2.5% | 1,984 → 2,089 | 6,248 → 4,604 |
| 0 | GET / | 512 | +1.4% | 3,718 → 3,733 | 6,262 → 6,641 |
| 0 | GET /user/42 | 64 | +1.9% | 636 → 633 | 1,163 → 1,855 |
| 0 | GET /user/42 | 256 | +3.4% | 2,385 → 2,334 | 3,079 → 3,820 |
| 0 | GET /user/42 | 512 | +1.2% | 4,624 → 4,510 | 5,723 → 8,198 |
| 0 | POST /user | 64 | +4.1% | 568 → 600 | 1,057 → 2,524 |
| 0 | POST /user | 256 | +1.8% | 2,209 → 2,135 | 4,661 → 5,470 |
| 0 | POST /user | 512 | +5.2% | 4,014 → 3,812 | 6,188 → 4,804 |
| 8 | GET / | 64 | +16.6% | 698 → 612 | 1,503 → 14,360 |
| 8 | GET / | 256 | +17.8% | 2,617 → 2,331 | 3,263 → 3,498 |
| 8 | GET / | 512 | +26.9% | 5,159 → 4,498 | 7,615 → 7,984 |
| 8 | GET /user/42 | 64 | +12.3% | 826 → 724 | 1,317 → 1,171 |
| 8 | GET /user/42 | 256 | +18.8% | 3,249 → 2,700 | 4,012 → 3,711 |
| 8 | GET /user/42 | 512 | +14.2% | 4,146 → 5,238 | 8,193 → 9,463 |
| 8 | POST /user | 64 | +16.3% | 778 → 688 | 2,428 → 3,203 |
| 8 | POST /user | 256 | +22.2% | 2,866 → 2,621 | 4,048 → 3,101 |
| 8 | POST /user | 512 | +21.0% | 4,520 → 4,824 | 8,342 → 6,479 |

Throughput medians improve in every cell, especially with more headers, and
server CPU ticks per fixed request count decrease. Server process-lifetime
VmHWM is essentially unchanged (~24 MiB). CPU/rusage envelopes include client
startup/export/cleanup; server VmHWM is not a fresh per-cell peak or allocation
count. There is zero cgroup CPU throttling and zero sampled TCP retransmission,
input error, reset, timeout, listen overflow/drop, backlog drop or memory pressure
counter delta. Shared-host/VM interference remains possible despite these checks.
All per-round metrics, controls and resource deltas remain in the JSON.

Acceptance is withheld: GET `/` c64 p99.999 worsens in all four paired rounds
for both header workloads, with rich-header median 1.50 → 14.36 ms. Rich-header
GET `/user/42` c512 p99 median also worsens 4.15 → 5.24 ms. A selected follow-up
completed six alternating before/after rounds of **two million requests per
sample**, latency-enabled only, with 100,000 warm-up requests: GET `/` c64
with 0/8 extra headers and GET `/user/42` c512 with 8 extra headers. All
36 samples/72 million measured requests passed count, body, loop, TCP option,
exit-status and preflight parity checks. Source and binaries stayed frozen.
There was zero cgroup CPU throttling and no server major page faults.

| Extra headers | Route/concurrency | p99 before → after, ms | p99.999 before → after, ms | Candidate p99.999 worse in paired rounds |
| ---: | --- | ---: | ---: | ---: |
| 0 | GET /, c64 | 0.518 → 0.509 | 12.74 → 24.34 | 3/6 |
| 8 | GET /, c64 | 0.707 → 0.642 | 4.24 → 15.91 | 4/6 |
| 8 | GET /user/42, c512 | 5.68 → 5.20 | 58.95 → 30.45 | 2/6 |

Longer runs do not reproduce a consistent paired regression: root c64 tails
are mixed, while the user c512 p99 median reverses its primary direction.
However root c64 p99.999 medians remain worse for both workloads. Both binaries
also suffer large stalls (baseline root c64 worst sample p99.999 337.96 ms,
candidate 98.00 ms), so this does **not** prove the views cause the stalls.
No rounds are discarded. The conservative decision is rejection because a safe
tail gate was not established, rather than declaring a win from throughput
alone. Server CPU reduction and near-identical process-lifetime RSS do not
override that gate. No further responder/streaming acceptance campaign was run
for the withdrawn candidate. No external Express+Bun, Hono+Bun or Actix
comparison was run here. The overall goal remains active.

After withdrawal, the final baseline release gate passed: **455 XCTest tests
(8 diagnostic skips), 102 Swift Testing tests, zero failures**, and all five
release products built. Candidate counts above describe the tested experiment.
Final source and validation-log hashes are recorded separately in the JSON.

Local artifacts: `/tmp/wt-linux/header-views/`; completed primary native archive:
`/tmp/wt-linux/header-views/network-results/`. Completed confirmation archive:
`/tmp/wt-linux/header-views/confirmation-results/`. These temporary paths are
not permanent public downloads. No non-Swift implementation source was added.
