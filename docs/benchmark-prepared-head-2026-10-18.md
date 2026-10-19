# Deferred prepared request-head conversion — 2026-10-18

> Socket-option erratum: historical `tcp_nodelay=off` / override `0` labels did not prove TCP_NODELAY was disabled. The old client skipped its override while NIO enabled TCP_NODELAY by default; its explicit `1` used the wrong option level. See [the correction and validation](benchmark-socket-options-2026-10-18.md). Raw measurements are preserved; rebaseline with verified socket values.


**Decision: rejected.** Both the four-round network campaign and six-round
long confirmation are complete. Prepared throughput and server CPU improved,
but root c256 extreme-tail latency regressed. The production candidate was
restored to baseline; the added tests and diagnostic remain. The full
performance goal is not achieved.

## Isolated change and invariants

Production baseline: `31f3be69b4e08550d1a3d0a99ceb8a733ebb0c4e`.
Tier 1 previously invoked `convertHead` before checking its minimal-route cache.
The candidate moves conversion into cached sync/future branches and below the
cache block for general dispatch. A prepared cache hit returns without that
call. Cache eligibility, method/URI identity, framing, writer, header validation,
middleware and request-streaming fallback are unchanged. No Task, future,
lock, unsafe annotation or dependency was added by this runtime experiment.
No allocation counter was collected; source call placement alone does not
prove a particular number of removed allocations.

The diagnostic now also constructs an immutable prepared response at fixture
setup. Two new equivalence tests exercise prepared cache hits followed by
method/URI changes, HEAD, absent/mixed-case Host, query changes, buffered and
chunked bodies, HTTP/1.0 keep-alive, extra headers and Connection: close.
They passed against baseline before runtime editing. Candidate release
validation passed 453 XCTest tests (8 diagnostic skips) plus 102 Swift Testing
tests, zero failures. All five release products built.

## Environment and method

Swift 6.4 release, SwiftNIO 2.104.0, Linux aarch64 Docker on Apple M1 Pro.
Two server loops on guest CPUs 0–3; corrected client uses four requested and
observed loops on guest CPUs 4–7, client override flag `TCP_NODELAY=0` (effective value unverified). The same immutable
client binary is used in both phases and all controls. This is a shared-host,
colocated-generator experiment, not bare-metal or independent-generator evidence.

Four rounds reversed server order between rounds. Each route/concurrency/server
cell received 50,000 warm-up requests then 500,000 requests separately with
latency disabled/enabled. Routes: GET `/` (root), GET `/prepared` (prepared body),
GET `/user/42` (sync parameter), POST `/user` (post); concurrency 64/256/512;
servers before/after Tier 1, stock and raw NIO. All 384 samples completed,
192 million measured requests, with expected body counts and actual four-loop
client usage. Preflight status, headers and bodies matched byte-for-byte across
all four modes. For POST, the pinned NIO request encoder adds `Transfer-Encoding: chunked`
and the client ends the empty body with a terminal chunk. It does not qualify
for the minimal-header shortcut, making it a useful fallback control. The
client source sets Host; the codec supplies this POST framing on the wire.

## Four-round results

Medians; latency is in microseconds. Full rounds, ranges, p50/p90/max, CPU,
RSS, body throughput and cgroup resource deltas are in the
[machine-readable record](benchmark-data/prepared-head-2026-10-18.json).

| Route | Connections | RPS before → after | p99 before → after | p99.999 before → after |
| --- | ---: | ---: | ---: | ---: |
| root | 64 | 240,845 → 272,276 (+13.1%) | 719 → 641 | 3,243 → 3,723 |
| root | 256 | 252,827 → 281,424 (+11.3%) | 2,273 → 2,242 | 6,304 → 7,331 |
| root | 512 | 256,331 → 288,344 (+12.5%) | 4,608 → 4,058 | 11,083 → 9,161 |
| prepared | 64 | 244,702 → 284,706 (+16.3%) | 706 → 697 | 3,262 → 5,042 |
| prepared | 256 | 255,210 → 289,276 (+13.3%) | 2,960 → 2,719 | 22,026 → 9,382 |
| prepared | 512 | 259,546 → 284,106 (+9.5%) | 4,630 → 4,521 | 15,551 → 11,648 |
| user | 64 | 194,690 → 193,927 (-0.4%) | 702 → 773 | 2,428 → 3,414 |
| user | 256 | 200,567 → 202,070 (+0.7%) | 2,586 → 2,692 | 7,649 → 8,222 |
| user | 512 | 206,022 → 204,462 (-0.8%) | 5,080 → 5,163 | 11,859 → 11,251 |
| post | 64 | 218,924 → 216,341 (-1.2%) | 715 → 716 | 3,946 → 3,441 |
| post | 256 | 225,238 → 226,202 (+0.4%) | 2,634 → 2,769 | 7,630 → 7,486 |
| post | 512 | 227,316 → 227,621 (+0.1%) | 4,701 → 4,792 | 11,278 → 10,952 |

Prepared throughput improves by 9–16% on these samples; this does not establish
an overall win. Prepared c64 p99.999 worsens about 55%, sync c64 p99 about 10%,
and root c256 p99.999 about 16%. Other cells improve or remain close. No samples
were discarded. The embedded prepared Tier 1 median fell from 1,420 to 1,357
ns/request (six rounds), while sync rose from 1,841 to 1,997 ns/request.
That sync diagnostic signal must remain visible beside the prepared benefit.

No CPU-quota throttling events were recorded in the four-round campaign.
CPU/RSS counters are observational: CPU ticks bracket the client process,
including export, and VmHWM includes preceding cells in each long-lived server.
No hardware cycle/instruction profile was collected.

## Six-round long confirmation

The exact four binaries from the first campaign were reused (verified hashes).
Six rounds reversed server order; each cell received 200,000 warm-up requests
then 2,000,000 measured requests with latency enabled. Selected cells were
root c64/c256, prepared c64 and sync user c64. All 96 samples completed,
192 million measured requests, with expected body counts, latency sample counts
and four observed client loops. Preflight headers/bodies still matched across
all controls. No samples were removed; this campaign is preserved separately
from the first campaign rather than silently pooled into it.

Medians of six rounds; microseconds:

| Route / connections | p99 before → after | p99.999 before → after | maximum before → after |
| --- | ---: | ---: | ---: |
| root / 64 | 843 → 725 | 33,774 → 7,962 | 37,036 → 8,393 |
| root / 256 | 2,570 → 2,567 | 9,316 → 23,524 | 10,369 → 25,576 |
| user / 64 | 807 → 806 | 19,485 → 7,211 | 21,867 → 8,377 |
| prepared / 64 | 803 → 722 | 10,433 → 7,497 | 14,372 → 8,528 |

The initial c64 regression pattern did not repeat consistently. Root c256,
however, had worse p99.999 in five of six paired rounds and its median rose
about 2.5 times. This fails the tail acceptance gate, despite the real cost
reduction signal. Median server CPU ticks per two million requests fell from
1,606 to 1,409.5 for root c64, 1,522 to 1,363 for root c256, and 1,546.5 to
1,327.5 for prepared c64 (100 ticks/second); user c64 was approximately neutral
at 2,018.5 → 2,007. RSS medians were roughly 22,290 → 22,652 KiB. These CPU/RSS
observations have the same envelope/high-water limitations as the first campaign.
Latency-enabled RPS is recorded separately and does not replace primary RPS.

Cgroup counters recorded zero CPU-quota throttling and zero memory-limit/OOM
events in this confirmation. Pressure deltas remain in the JSON. This does not
exclude macOS host/VM scheduling delays, and large excursions also occur in
controls (for example raw root c256 median p99.999 about 56.5 ms). The campaign
does not isolate the causal mechanism. It does establish that the candidate
has not met the required non-regression evidence.

**Decision remains rejected.** Only the measured production runtime edit was
reverted. Correctness tests and the prepared diagnostic remain useful for
future work. Local confirmation logs are under
`/tmp/wt-linux/prepared-head/confirmation/`; all verified samples and resource
counters are in the JSON's `long_confirmation` section. Next work should
investigate event-loop/network scheduling and collector effects before making
another hot-path patch; repeated throughput improvements alone are insufficient.

Raw logs, binaries, the patch, source manifest and scripts are locally under
`/tmp/wt-linux/prepared-head/`. The JSON records immutable binary hashes and
all candidate Swift source hashes, but the temporary raw archive is not a
public durable download. The rejected patch remains in that local archive. Runtime source is restored
to baseline, so no architecture invariant change was retained. Final retained-work release validation passed as recorded below.


## Final retained-work validation

After reverting the runtime edit, `swift test -c release` passed on Swift 6.4
Linux: 453 XCTest tests (8 diagnostic skips), 102 Swift Testing tests, zero
failures. All five release products built: example, framework benchmark server,
raw NIO benchmark server, benchmark client and runtime benchmark server.
`git diff --check` passed; all production `Sources/` match baseline HEAD.
The new equivalence tests, prepared diagnostic and earlier client loop fix
remain in the worktree. No non-Swift implementation source was added.

## Archived runtime diff

This is the exact rejected production edit, preserved for reproduction and
future diagnosis; it is not applied to the retained runtime. The source and
binary hashes in the data identify the measured candidate.

```diff
diff --git a/Sources/WhiteThroatedRuntime/WTHTTP1ConnectionHandler.swift b/Sources/WhiteThroatedRuntime/WTHTTP1ConnectionHandler.swift
index 535948b..79e7012 100644
--- a/Sources/WhiteThroatedRuntime/WTHTTP1ConnectionHandler.swift
+++ b/Sources/WhiteThroatedRuntime/WTHTTP1ConnectionHandler.swift
@@ -272,11 +272,6 @@ public final class WTHTTP1ConnectionHandler:
     ) {
         let method = head.method
         let uri = head.uriBytes()
-        let nioHead = convertHead(
-            head,
-            method: method,
-            uri: uri
-        )
         let isHeadRequest = method == .head

         // Minimal-header fast path, mirroring stock: cache hit on
@@ -300,6 +295,7 @@ public final class WTHTTP1ConnectionHandler:
                     return

                 case .sync(let action):
+                    let nioHead = convertHead(head, method: method, uri: uri)
                     writeSyncMinimal(
                         action.run(
                             RuntimeRequest(
@@ -314,6 +310,7 @@ public final class WTHTTP1ConnectionHandler:
                     return

                 case .async(let action):
+                    let nioHead = convertHead(head, method: method, uri: uri)
                     writeFuture(
                         action.run(
                             RuntimeRequest(
@@ -340,6 +337,9 @@ public final class WTHTTP1ConnectionHandler:
             }
         }

+        // A prepared minimal-cache hit needs no NIO request head. All
+        // other paths retain conversion before dispatcher/request use.
+        let nioHead = convertHead(head, method: method, uri: uri)
         let hasStreamingRouteForRequest =
             hasStreamingRoutes
             && dispatcher.hasStreamingRoute(
@@ -2503,9 +2503,8 @@ public final class WTHTTP1ConnectionHandler:
         return address
     }

-    /// Tier 1 boundary conversion: one NIO request head per request.
-    /// This is the known conversion tax the experiment measures; the
-    /// dispatcher contract itself is unchanged.
+    /// Tier 1 boundary conversion, skipped only for a validated prepared
+    /// minimal-cache hit. The dispatcher contract itself is unchanged.
     private func convertHead(
         _ head: WTHTTP1RequestHead,
         method: WTHTTP1Method,
```
