# Canonical response experiment — 2026-10-18

> Socket-option erratum: historical `tcp_nodelay=off` / override `0` labels did not prove TCP_NODELAY was disabled. The old client skipped its override while NIO enabled TCP_NODELAY by default; its explicit `1` used the wrong option level. See [the correction and validation](benchmark-socket-options-2026-10-18.md). Raw measurements are preserved; rebaseline with verified socket values.


**Decision: rejected.** The short canonical-response serializer reduced local
serialization cost and improved parameter-route throughput, but extreme-tail
latency worsened at all three tested connection counts. The production changes
and their candidate-only tests were reverted. The canonical diagnostic fixture
remains available for future experiments. No architecture invariant or public
API changed in the retained work.

## Candidate and correctness

Starting production commit: `31f3be69b4e08550d1a3d0a99ceb8a733ebb0c4e`.
The candidate prewarmed immutable slices for 195 validated HTTP/1.1 heads:
three canonical content types and 0–64 UTF-8 body bytes. It proved eligibility
against actual status/reason bytes, ordered headers and body length before
copying the head and text directly into the output buffer. Other responses
kept the generic serializer. It introduced no Task, future, lock or unsafe
ownership annotation. Prepared and custom-header responses served as controls.

Six candidate tests passed, including size boundaries, Unicode, forged metadata,
header/body mutation, ByteBuffer copy isolation, HEAD/CONNECT, HTTP/1.0,
connection close and invalid headers. The candidate full release suite passed
457 XCTest tests (8 diagnostic skips) plus 102 Swift Testing tests. An additional
HTTP/1.0 keep-alive assertion was added after that run but was not run before
rejecting the candidate; it is not counted as validated evidence.

## Environment and method

Swift 6.4 release; SwiftNIO 2.104.0; Linux aarch64 Docker on Apple M1 Pro.
Each server used two event loops on CPUs 0–3. The immutable corrected client
used four requested **and observed** loops on CPUs 4–7, override flag `TCP_NODELAY=0` (effective value unverified).
Both phases used the same corrected generator; historical two-loop results
were not mixed into this comparison.

Four measured rounds reversed server order between rounds. Each cell received
50,000 warm-up requests, then 500,000 measured requests separately with latency
disabled/enabled. GET `/`, GET `/user/42`, and POST `/user` ran at 64/256/512
connections against before/after Tier 1, stock NIO and raw NIO. GET `/plaintext`
(custom-header fallback) ran at 256 connections with 250,000 measured requests;
raw NIO has no matching route and was excluded there. There were 312 samples,
150 million measured requests. All samples completed with expected response-byte
counts and four observed client loops. Preflight status, headers and bodies
matched byte-for-byte across equivalent modes; hashes and bytes are in the data.

## Results

GET `/user/42`, medians of four rounds; latency values are microseconds:

| Connections | RPS before → after | p99 before → after | p99.999 before → after |
| --- | ---: | ---: | ---: |
| 64 | 205,686 → 220,801 | 744 → 703 | 1,838 → 4,052 |
| 256 | 212,593 → 230,196 | 2,737 → 2,747 | 4,662 → 6,678 |
| 512 | 211,596 → 230,506 | 4,918 → 5,358 | 8,280 → 9,595 |

The targeted embedded canonical diagnostic fell from 2,024 to 1,639 ns/op
(medians of six rounds). Network throughput rose approximately 7–9% on the
parameter route, but its p99.999 rose about 120%, 43%, and 16% respectively.
At 512 connections p99 also increased about 9%. These observations fail the
acceptance gate; a local cost reduction cannot justify claiming a general win.
Other cells were mixed, including a POST c64 extreme-tail increase. No outliers
were removed. The experiment does not prove that the code alone caused every
VM scheduling excursion; it also does not establish non-regression.

Server process-lifetime high-water RSS medians were 23,884 KiB before and
24,358 KiB after.
These counters include earlier cells in the same process. CPU ticks, full RPS,
latency distributions (including p50/p90/max), body counts and per-round ranges
are retained in the [machine-readable record](benchmark-data/canonical-response-2026-10-18.json).
The same file includes a separate two-round fresh baseline of 108 samples using
the corrected client; it is diagnostic baseline evidence, not a universal win.

## Reproducibility and limits

The data records immutable binary hashes and a manifest of every candidate
Swift runtime source, including its previously untracked source file. Local
raw logs, scripts, binaries and the rejected patch remain under
`/tmp/wt-linux/canonical-response/`; this temporary archive is not a durable
public download. Production source is restored to the starting commit.

This shared-host VM campaign uses a colocated generator and request-count runs.
Extreme quantiles contain few samples; four rounds do not establish a stable
population tail distribution. No hardware counters were collected. No new
Express+Bun, Hono+Bun or Actix measurement was run. Further work must diagnose
tail excursions and repeat the external/control matrix with the corrected
client before asserting leadership across all aspects.


## Retained-work validation

After restoring production runtime source, `swift test -c release` passed on
Swift 6.4/Linux: 451 XCTest tests (8 diagnostics skipped) and 102 Swift Testing
tests, zero failures. The real-channel benchmark-client regression passed all
five configured thread counts. Release builds passed for
`whitethroated-example`, `whitethroated-benchmark-server`,
`raw-nio-benchmark-server`, `whitethroated-benchmark-client`, and
`whitethroated-runtime-benchmark-server`. `git diff --check` passed.


## Longer confirmation

A separate six-round confirmation reused the exact four immutable binaries and
corrected client (hashes match the initial campaign). It measured GET
`/user/42` at 64/256/512 connections, latency enabled, with 200,000 warm-up
requests and 2,000,000 measured requests per sample. Server order alternated
between forward and reverse. All 72 samples completed: 144 million measured
requests, expected 4 million body bytes per sample, `requests - connections`
latency samples and four observed client loops. No source/build changes ran
during the measurement. This is a separate experiment, not extra rounds silently
pooled into the first campaign.

Medians of six rounds, microseconds:

| Connections | p99 before → after | p99.999 before → after | maximum before → after |
| --- | ---: | ---: | ---: |
| 64 | 828 → 841 | 5,681 → 27,848 | 6,832 → 29,554 |
| 256 | 2,967 → 2,940 | 20,435 → 8,642 | 23,727 → 10,333 |
| 512 | 5,339 → 4,993 | 43,797 → 43,391 | 45,425 → 45,391 |

**Decision remains rejected.** The initial all-concurrency tail pattern did
not reproduce: c256 improved and c512 was approximately neutral. However,
c64 p99.999 worsened in five of six paired rounds and its median rose about
4.9 times. The full record also shows large excursions in stock and raw NIO;
this shared-host experiment does not isolate their root cause. Longer runs
increase exposure to occasional scheduling stalls as well as the number of
observations supporting the extreme quantile; compare within each campaign.
Latency-enabled RPS is retained separately and is not substituted for primary
throughput-only RPS.

Cgroup CPU and memory pressure/event counters were captured before and after
each sample. There was one CPU-quota throttling event, 53,944 microseconds,
in round 3 stock c256; no memory-limit/OOM events or memory pressure were
recorded. CPU-pressure totals are available per sample. These counters cover
the container and cannot exclude delays in the macOS host or VM scheduler.
No samples, including the throttled control, were discarded. The data file's
`long_confirmation` section preserves all metrics, ranges and resource deltas.
Local confirmation logs remain in `/tmp/wt-linux/canonical-response/confirmation/`.

The next isolated cost center is Tier 1's eager `convertHead` before a prepared
minimal-route cache hit. That branch returns without using the converted head.
Deferring conversion could remove header/String materialization there, but must
retain exact method/URI/minimal-header eligibility and unchanged sync/future,
middleware, framing and cache-invalidation behavior. Compiler elimination and
network benefit have not yet been measured; this is a hypothesis, not a result.
