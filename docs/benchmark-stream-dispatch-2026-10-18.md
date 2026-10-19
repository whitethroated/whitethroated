# Response-stream dispatch experiment (2026-10-18)

> Socket-option erratum: historical `tcp_nodelay=off` / override `0` labels did not prove TCP_NODELAY was disabled. The old client skipped its override while NIO enabled TCP_NODELAY by default; its explicit `1` used the wrong option level. See [the correction and validation](benchmark-socket-options-2026-10-18.md). Raw measurements are preserved; rebaseline with verified socket values.


Baseline: `31f3be69b4e08550d1a3d0a99ceb8a733ebb0c4e`. This experiment
isolates stream-writer transport dispatch; it does not complete the
[broader performance goal](performance-goal-status.md).

## Cost center and invariant

The old runtime constructs closures for buffered writes, flushing writes,
and flush. Tier 1 captures its handler, context, and request sequence in the
write closures. The candidate stores those concrete references directly;
stock dispatch writes HTTP parts and Tier 1 dispatch calls the existing
framing methods. No protocol, existential, Task, lock, or extra future is
introduced. Ordinary routing and response serialization are unchanged.

Event-loop preconditions, declared-length tracking, synchronous buffered
write success, transport-linked flushing futures, explicit flush timing,
file regions, post-end writes, and disconnect semantics remain unchanged.
Existing equivalence and response-stream suites exercise both transports.

The candidate production diff SHA-256 is
`99df1e78f5a240837e3f3f80a144517f83909fc41911750eff64e15bdce86aa1`.
Before/after server binaries are preserved outside the repository in
`/tmp/wt-linux/stream-dispatch/`.

## Correctness and local diagnostic

Both versions pass the full Swift 6.4 Linux release suite: 450 XCTest tests
(8 opt-in diagnostics skipped) and 102 Swift Testing tests, zero failures.
The HTTP/1 equivalence suite has 65 cases. The diagnostic checks response
bytes before timing, warms both transports, then performs six alternating
rounds of 100,000 requests per case through active EmbeddedChannels.

| Case | Before median ns/op | Candidate median ns/op |
|---|---:|---:|
| Stock synchronous control | 3168 | 3123 |
| Tier 1 synchronous control | 1770 | 1796 |
| Stock chunked stream | 4605 | 4514 |
| Tier 1 chunked stream | 3847 | 3682 |

The Tier 1 stream median drops about 4.3%; two candidate stream rounds
still reach approximately 4176–4179 ns. This is a local diagnostic result,
not evidence that every network percentile improves.

Release producer disassembly has four direct `swift_allocObject` call
sites before and two after. Static retain-call sites (including retain_n)
drop from 37 to 18 and release-call sites from 25 to 8 in that function.
The function spans 2088 bytes before and 1176 after. These are static
machine-code observations, not dynamic whole-request allocation counters.
The producer completion callback still exists; only transport dispatch
closures are removed.

## Network experiment

Swift 6.4, pinned SwiftNIO 2.104.0, release products; Apple M1 Pro host,
Docker Desktop Linux VM with 8 vCPUs. Two server event-loop threads pinned
to CPUs 0–3; the same unmodified client pinned to CPUs 4–7 requests four
threads but uses two channel loops due to the existing harness issue.
HTTP/1.1 keep-alive, client override flag `TCP_NODELAY=0` (effective value unverified), no TLS or compression.

Before/after Tier 1 and before/after forced-stock servers use the same
routes, status, payload, and relevant headers. Known-length, chunked, and
explicit-flush response streams are tested at c64/c256/c512. Unchanged
GET /, GET /user/42, and POST /user controls are sampled at c256 only;
this is not a fresh full ordinary-route or cross-framework campaign.

Every cell receives 20,000 warm-up requests followed by separate throughput
and latency samples of 250,000 requests. Four rounds alternate server order.
CPU ticks and process-lifetime peak RSS accompany each sample. Body bytes
and completed request counts are checked by the external summarizer.

During this campaign, the container reports `cpu.max=800000 100000`,
effective CPUs 0–7, `nr_throttled=0`, and `throttled_usec=0`. Container CPU
quota exhaustion is therefore not supported as the explanation for the
observed tail excursions. Host/VM scheduling and client-loop behavior
remain separate hypotheses; neither is established as the cause.

All 384 samples completed, totaling 96 million measured requests, with no
client failures. Exact preflight response headers/bodies and aggregate body
counts match across controls. Full measurements and all diagnostic rounds are
preserved in [the data](benchmark-data/stream-dispatch-2026-10-18.json).

Tier 1 medians below are `throughput RPS / p99 microseconds`, from separate
throughput-only and latency-enabled runs:

| Stream | Connections | Before | Candidate |
|---|---:|---:|---:|
| Known length | 64 | 138,183 / 884 | 143,856 / 847 |
| Known length | 256 | 143,519 / 2171 | 143,676 / 2881 |
| Known length | 512 | 140,920 / 4506 | 145,266 / 4977 |
| Chunked | 64 | 124,544 / 990 | 127,669 / 1074 |
| Chunked | 256 | 125,126 / 2897 | 129,644 / 2999 |
| Chunked | 512 | 127,194 / 4314 | 130,204 / 5640 |
| Explicit flush | 64 | 100,923 / 1275 | 103,688 / 1397 |
| Explicit flush | 256 | 100,994 / 3928 | 104,059 / 3197 |
| Explicit flush | 512 | 101,216 / 5669 | 105,238 / 5850 |

Maximum observed RSS is 23,880 KiB before Tier 1, 23,876 candidate Tier 1,
25,024 before stock, and 24,648 candidate stock. The per-run CPU ticks and
stock/ordinary-route control results remain in the data. No equivalent raw
stream control or external-framework stream campaign was run here, so this
experiment does not establish a framework-tax or external ranking result.

## Longer tail confirmation and rejection

The first matrix has higher median p99 in several cells. Brief symbol
inspection also occurred early in that matrix; all samples are retained.
A separate confirmation ran without concurrent profiling, with 250,000
warm-up requests and 1,000,000 measured requests per sample, four alternating
before/candidate rounds on the three concerning cells. These 24 additional
samples complete another 24 million requests, with verified body counts.
The client, CPU placement, and server thread counts remain the same. This
latency-only diagnostic does not collect additional CPU/RSS counters.

| Cell | Before p99 us | Candidate p99 us |
|---|---:|---:|
| Known length c256 | 2230 | 2011 |
| Known length c512 | 3956 | 3850 |
| Chunked c512 | 4392 | 4254 |

The median p99 improvements do not hold across the entire tail. Chunked
c512 candidate p99.999 rounds are 31,516 / 8163 / 43,067 / 36,088 us,
versus 9167 / 9124 / 8456 / 9230 us before. The median rises from about
9.1 ms to 33.8 ms. Candidate maximum rounds reach 31,941 / 8292 /
43,093 / 39,112 us, versus 10,823 / 9954 / 10,073 / 9381 us before.

**Candidate rejected; both runtime files are restored to `31f3be6`.**
Lower allocation-site counts, better streaming RPS, and lower median p99
do not satisfy an all-aspects target when the extreme-tail profile regresses.
The precise mechanism is unresolved; these measurements do not prove an
intrinsic property of concrete dispatch on other workloads or generators.
The change may be revisited only with new evidence, including the corrected
client's fresh baseline. No production runtime optimization from this
experiment is retained.

External scripts, binaries, the rejected candidate patch, and raw logs remain
under `/tmp/wt-linux/stream-dispatch/`. No non-Swift benchmark source is added
to the repository. The tracked JSON retains the complete measured results.
