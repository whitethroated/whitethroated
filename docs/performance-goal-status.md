# Performance goal status

Goal: WhiteThroated should lead across all tested aspects while preserving
HTTP correctness, security, and reproducible comparisons. **Not achieved.**
The default-transport validation contains mixed results and material tail
regression signals; a green correctness suite is not proof of that goal.

## Completion evidence still needed

- Release correctness and regression suites must remain green, including
  parser/writer equivalence, framing validation, body limits, streaming
  backpressure, explicit flushes, length mismatches, and disconnects.
- A fresh comparison must cover the established endpoint/concurrency matrix
  and its responder/streaming controls with matched response semantics.
- Measure throughput, average latency, p50, p75, p90, p99, p99.999, maximum,
  the predeclared p99/mean consistency metric, CPU, peak RSS, and body
  throughput where applicable. Retain per-round results and errors.
- Compare the same WhiteThroated path before/after, equivalent raw SwiftNIO,
  then the external Express+Bun and Hono+Bun controls. Verify and record
  current external versions before the new campaign. Preserve the Actix
  reference's equivalence requirements when updating that comparison.
- A best-case configuration for one metric must not be presented as one
  configuration winning every metric. Keep worker-count/topology tradeoffs
  and absolute tail latency visible beside consistency ratios.
- Diagnose the outstanding c512 tail excursions and repeat relevant cells;
  no universal tail-latency win is currently supported. VM results do not
  establish a bare-metal or independent-generator result.

## Current evidence and next cost centers

The baseline at `31f3be6` plus the current retained fixes passes 455 XCTest
tests (8 opt-in diagnostics
skipped) and 102 Swift Testing tests on Swift 6.4/Linux. Its
[default-transport report](benchmark-tier1-default-2026-10-18.md) records the
remaining performance gaps rather than declaring a full win.

The [stream-dispatch experiment](benchmark-stream-dispatch-2026-10-18.md)
replaced capturing sink closures with concrete transport references. It passed
correctness, removed two producer allocation call sites, and improved several
metrics. It was rejected after longer measurements showed worse chunked c512
p99.999. Both runtime files are restored; all measured results remain available.

Further identified work, after that isolated experiment:

1. The benchmark client's double `group.next()` advance has been corrected:
   each connection and its completion promise select the same loop once.
   Real-channel regression coverage checks 1/2/3/4/8 requested threads.
   The full Swift 6.4 release suite passes with retained regressions: 454 XCTest tests
   (8 diagnostics skipped), 102 Swift Testing tests, and all five release
   products build. A fresh Swift-side baseline now covers raw NIO, stock
   and Tier 1 on three routes at 64/256/512 connections (two rounds).
   External-control preflight on 2026-10-18 verified installed Bun Linux
   1.4.3 (`1.4.3+c6da4a4d3`), Express 5.3.0 and Hono stable 4.13.13
   against official release/registry sources; fingerprints are in the
   canonical experiment data. External and streaming controls still need
   fresh baselines; historical
   results must not be mixed with this generator.
2. The [canonical-response experiment](benchmark-canonical-response-2026-10-18.md)
   tested prevalidated short response heads and direct text serialization.
   Its 312-sample, four-round A/B improved parameter-route RPS by about 7–9%,
   but p99.999 worsened at every tested concurrency. It was rejected and
   production files restored. Candidate correctness passed; neither this
   nor the microbenchmark improvement proves a production performance win.
   A separate six-round confirmation (72 samples, 144 million requests)
   retained the rejection: c64 p99.999 worsened about 4.9 times, while c256
   improved and c512 was approximately neutral. Large control excursions
   remain unexplained. Full metrics, resource deltas and corrected-client
   baseline are preserved in the report's data file. Tail behavior remains
   a gate. The prepared-cache conversion hypothesis was then tested in the
   separate experiment below.
3. The [prepared-head experiment](benchmark-prepared-head-2026-10-18.md) was
   rejected. The candidate passed correctness and improved prepared throughput
   by 9–16% in 384 samples. A separate 96-sample, six-round long confirmation
   found root c256 p99.999 worsening in five of six rounds (median 9.3 →
   23.5 ms), despite lower server CPU cost. Production source is restored;
   the two new regression tests and prepared diagnostic remain. Investigate
   event-loop/network scheduling and collector effects before another runtime
   patch; raw/stock controls also show large excursions. Neither campaign
   establishes a universal latency win or its causal mechanism.
4. A [socket-option bug](benchmark-socket-options-2026-10-18.md) was reproduced
   and fixed. Wrong SOL_SOCKET TCP_NODELAY calls failed; legacy client flag 0
   only skipped an override while NIO defaulted to on. Historical off labels
   were not actual socket observations. Corrected client explicitly applies
   and verifies 0/1/default; framework/raw setup uses the TCP level and propagates
   option failure. Real-socket regressions and the full release suite pass
   (454 XCTest, 8 skips; 102 Swift Testing; five products). A selected verified-
   socket diagnostic completed (36 samples, 18 million requests, root c256).
   Both actual values still show tail variation; at default actual 1, Tier 1
   still trails stock/raw p99.999 in this selected sample. No retransmissions
   or cgroup throttling were observed, but process page faults/context-switch
   envelopes need deeper diagnosis. The [executable-placement diagnostic](benchmark-executable-placement-2026-10-18.md)
   then completed 36 further samples (18 million requests), same client hashes
   and libraries, actual TCP_NODELAY=1. Local storage removed 26 process major
   faults, but tail latency did not improve consistently (Tier 1 median
   p99.999 9.5 → 12.2 ms). No runtime edit or performance win resulted. A perf probe
   is permission-denied, but an isolated userspace CPU sampler captured 4,722
   samples over three controls and six million diagnostic load requests.
   Independent [ELF symbol validation](benchmark-cpu-symbol-validation-2026-10-19.md)
   now resolves 93.7–95.3% of flat samples and matches selected flat/cumulative
   anchors; unknown labels remain unknown. The isolated [header-view experiment](benchmark-header-views-2026-10-19.md)
   preserved owned URI/cache keys and passed candidate correctness validation
   (456 XCTest, 9 skips; 107 Swift Testing; five release builds). Local codec
   cost fell about 28%, and 576 native samples/288 million requests showed RPS
   median gains of 1–5% with no extra headers and 12–27% with eight. Root c64
   p99.999 worsened in all four primary paired rounds. A six-round selected-tail
   confirmation (36 samples/72 million requests) still had worse root c64
   p99.999 medians, with mixed paired ratios and large stalls on both binaries.
   The candidate was rejected because the tail gate was not established; the
   data do not prove source-level causality. Production changes and candidate-only
   API tests were withdrawn and archived; wire-equivalence coverage and the
   richer-header pipeline fixture remain. Final baseline release revalidation
   passes 455 XCTest (8 skips), 102 Swift Testing and all five products. On-CPU profiles do not identify off-CPU or host/VM tail stalls.
   No rejected runtime patch was reintroduced.
   Rebaseline all controls before new claims; a full
   corrected route/concurrency/responder baseline is still missing.
5. The [stream error-mapping experiment](benchmark-stream-error-mapping-2026-10-19.md)
   removes one framework error-mapping future from every successful response
   stream write. Declared-length failures keep their public
   `ResponseStreamError` identity; foreign channel/producer errors remain
   unchanged. A four-round native A/B covered 144 samples and 72 million
   requests: throughput improved in all nine route/concurrency cells by
   2.6–7.6%, and p99 improved in eight cells while known-length c256 was
   approximately neutral. A separate six-round, 48-million-request latency
   confirmation found lower server CPU ticks for known c256 and flush c512;
   p99 was +1.7% and -5.4% respectively. p99.999 stayed noisy and is not
   claimed as improved: known c256 was approximately neutral and flush c512
   was 9% worse by median, with isolated 113–311 ms outliers and substantial
   flush retransmissions. The candidate is retained for its consistent
   throughput/CPU result, not as a universal tail win. Exact wire preflight,
   455 XCTest (8 skips), 102 Swift Testing, and five release products pass.
   The new opt-in raw stream control shows Tier 1 still trails the cached-head
   raw lower bound by roughly 15–35% throughput across the tested matrix.
6. Known-length c512 response streaming, the remaining raw-stream gap, and
   ordinary-route throughput gaps remain explicit gates. Eliminating one
   allocation site does not prove those gaps closed. A follow-up
   [prebuffered-chunk experiment](benchmark-stream-prebuffer-2026-10-19.md)
   tested whether the two small `writeString` conversions explain the gap.
   Across 108 samples and 54 million requests, setup-time immutable
   ByteBuffers lost throughput in all six tested mode/concurrency cells and
   in 17 of 18 paired rounds; p99 also worsened in all six median comparisons.
   The diagnostic routes were withdrawn. Small-string conversion is therefore
   not the next cost center for these 6–7 byte chunks.
7. A new opt-in runtime response-stream control now separates the remaining
   raw-to-framework gap. The
   [three-level stream matrix](benchmark-runtime-stream-layers-2026-10-19.md)
   completed 108 samples and 54 million requests with exact wire equality.
   Raw beat runtime and runtime beat framework in 17 of 18 paired throughput
   rounds. Median raw→runtime gaps were 5.6–14.1%; median
   runtime→framework gaps were 3.6–10.1%, with server CPU increasing in the
   same order in all six cells. The next work must address both runtime stream
   orchestration and the public framework bridge; neither layer alone explains
   the full deficit. Tail percentiles were mixed and remain non-winning.

The goal remains active until the full comparison and correctness evidence
support every required aspect. An individual optimization or partial matrix
does not complete it.
