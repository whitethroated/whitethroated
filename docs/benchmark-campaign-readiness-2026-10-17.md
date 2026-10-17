# Topology campaign readiness — measurements not started

Date: 2026-10-17, macOS Apple M1 Pro. The five-round performance campaign
was attempted at 17:27:16 Asia/Jakarta and rejected by its initial memory gate.
**No performance cell started. No new speed or latency claim follows.**

## Delivered apparatus

`whitethroated-benchmark-campaign` is a Swift-native driver for the next 1×8
versus 4×2 adjudication. It uses prebuilt release products, five alternating
rounds, all three contract routes and c64/c256/c512, with identical eight-shard
clients (one loop per shard). It verifies each worker's HTTP contract before
load and pools raw latency samples with the existing merger model.

The full plan contains 270 cells: separate throughput, latency and resource
modes. Resource mode observes worker RSS and cumulative CPU with `ps` about
every 250 ms. It reports sampled concurrent aggregate peak RSS and CPU deltas
with an explicit observation envelope; these are not process-lifetime peak
RSS or isolated handler service time. Primary throughput/latency modes do not
run that sampler. Preserve each mode separately.

The driver records before/after host checks, raw samples, worker/client logs,
HTTP verification data, resource observations, commit, worktree diff and
configuration. It aborts on host admission failure, HTTP mismatch, child
failure/timeout or HEAD change. It refuses to overwrite an existing output
directory and cleans up its own workers/clients on handled interruption.

## Actual preflight outcome

Recorded baseline: `c2ebb9eb28a93ec7b8350af655b8d8abca28036e`, with the
uncommitted campaign implementation. That commit appeared during harness
validation and was inspected before performance execution: it contains the
prior export/merge tooling, benchmark reports and launch settings; no runtime
source change. Local toolchain remains Apple Swift 6.2.4, not target Swift 6.4.

| Admission observation | Value | Gate |
|---|---:|---|
| One-minute load | 2.791 | Pass (<=4 on 8 logical cores) |
| Five-minute load | 3.798 | Pass (<=4) |
| Unrelated-process smoothed CPU sum | 78% | Pass (<=100%) |
| macOS kernel memory-pressure level | 2, warning | **Fail** (requires 1, normal) |

The [raw preflight observation](benchmark-data/topology-preflight-2026-10-17.json)
is retained in the repository. Full attempt metadata and `ABORTED.txt` are in
`/tmp/whitethroated-topology-quiet-attempt-20261017-1/`. No workers were launched
by that attempt. The gate was not disabled for performance measurements.

## Validation and fixed defect

The full release suite with subprocess regressions enabled passes: **376 tests,
4 existing skips, zero failures**. This includes new configuration/resource
parser tests, concurrent RSS peak aggregation, CPU counter deltas and zero-CPU
handling, refusal to reuse an output directory, occupied-port rejection before
worker launch and actual SIGTERM worker cleanup.

The interruption test initially exposed an actor-isolation trap in the signal
callback: a closure inherited main-actor isolation but executed on libdispatch's
global queue. The callback is now explicitly `@Sendable` and captures only the
lock-protected cancellation flag. The regression verifies a handled nonzero
exit, abort diagnostics and removal of the observed worker. A separate local
lifecycle check verified occupied-port rejection while preserving the unrelated
listener and cleanup of observed descendants. Identified leftover test workers
from the initial failing attempt were terminated; no user processes were stopped.

Initial control smoke attempts exposed a fixed-delay startup race: the raw and
runtime processes were alive but not listening after half a second. Readiness
now waits up to 30 seconds, retrying connection-refused startup failures only;
HTTP errors and response timeouts are never retried. Port availability is checked
with temporary loopback binds before launch. Ready/pre-warm RSS is captured only
after successful HTTP verification, avoiding pre-startup process measurements.

End-to-end smoke matrices exercise the three contract routes, both topologies,
pooled samples and resource output: 18 cells per product, 54 successful cells and
3456000 measured-phase requests in total. The framework smoke preceded readiness
hardening; raw/runtime smokes and lifecycle checks exercised the updated code.
Smoke mode bypasses quiet-host rejection,
uses one round/c64/8000 requests per shard, and marks outputs **SMOKE ONLY**.
It is correctness evidence only; competing smoke runs cannot supply performance
comparisons. Logs are under `/tmp/whitethroated-campaign-smoke-*-20261017*` and
`/tmp/whitethroated-campaign-lifecycle-b.log`. CI builds the merger/campaign;
Linux execution and Swift 6.4 validation remain pending until CI or a host runs.

## Exact retry

Complete release builds/tests before measurement. From the repository root,
use a fresh absolute output directory:

```sh
ulimit -n 10240
WHITETHROATED_CAMPAIGN_OUTPUT=/tmp/topology-five-rounds-unique \
  .build/release/whitethroated-benchmark-campaign
```

The runner will enforce the host gate again. Do not run tests, builds or other
benchmark campaigns alongside it. Do not treat `COMPLETE.txt` as acceptance:
inspect all round spreads, the +3% p50 guard, throughput, p90/p99 and memory.
If the p50 penalty repeats, reject process separation as a Pareto optimization
in this apparatus, even if p99 improves. Keep raw/runtime/framework and competitor
controls on the same apparatus before comparing their pooled results.

Full command/reference details are in BENCHMARKS.md. Linux topology transfer
remains pending under `linux-validation-checklist.md`; the runner prepares the
1×8/4×2 multi-port comparison but does not implement Linux reuseport, cache
counters or a replacement transport. No production runtime/API change or new
production dependency was made.
