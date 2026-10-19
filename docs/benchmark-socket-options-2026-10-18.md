# TCP socket-option correction — 2026-10-18

**A configuration bug was reproduced and fixed. No performance win is claimed.**
The earlier tail-diagnosis plan stopped during old-binary smoke, before any
planned measured samples. The failure exposed an incorrect socket-option level
and incorrect historical interpretation of the client flag.

## Root cause and historical interpretation

The old client and both Swift server initializers called
`ChannelOptions.socketOption(.tcp_nodelay)`. In pinned NIO 2.104.0,
`socketOption` selects SOL_SOCKET while `tcpOption` selects the TCP level.
On this Linux machine the wrong-level explicit `1` failed with errno 13,
Permission denied. This was not evidence that Docker prohibits TCP_NODELAY.
The correct TCP-level call succeeds in the same container without changing
permissions or capabilities.

For client flag `0`, the old code simply omitted that override. Pinned NIO's
`ClientBootstrap` already enables TCP_NODELAY by default. Thus historical
`tcp_nodelay=off` text described a configuration flag, not a queried socket value;
it did not establish that Nagle was enabled. Per-socket values were not recorded.
Server setup swallowed its wrong-level option failure, while NIO's server
bootstrap also set TCP_NODELAY on the listener by default. Listener inheritance
could therefore mask an ineffective accepted-socket override.

These statements follow the pinned source:
[option-level accessors](https://github.com/apple/swift-nio/blob/2.104.0/Sources/NIOCore/ChannelOption.swift),
[bootstrap defaults](https://github.com/apple/swift-nio/blob/2.104.0/Sources/NIOPosix/Bootstrap.swift).
Real-socket regression tests independently reproduce the accepted-child failure.

Historical raw metrics, completed-request counts, and binary hashes are unchanged.
Same-binary A/B comparisons still used a common client, but their socket labels
must be interpreted through this correction. The three new experiment JSON
records rename `client_tcp_nodelay` to `client_tcp_nodelay_override_flag`, mark
observed values unknown, and link this erratum. Do not silently reinterpret the
old flag-0 runs as newly verified flag-0 runs. Existing rejected optimizations
remain rejected; this metadata discovery alone does not demonstrate that their
tail regressions disappeared.

## Retained correction

- Framework and raw NIO accepted-channel setup use `tcpOption(.tcp_nodelay)=1`.
  A failed option future propagates to channel initialization instead of being
  swallowed. Framework setup is shared with its real-socket regression test.
- Client explicitly sets `tcpOption(.tcp_nodelay)` to 0 or 1, including its
  default enabled mode. After connecting each socket, it reads the value back
  before the throughput timer starts and fails on a mismatch.
- Output prints `tcp_nodelay_observed` after measurement. Both the setter and
  getter are connection-setup work; no per-request instrumentation was added.
- The earlier single-loop-selection fix remains in place, and actual channel
  loop counts are still reported.

There is no new package dependency, public framework API, Task, lock, request
allocation or ordinary request-path branch. This is a correctness/configuration
fix, not an optimization attributed to changed benchmark controls.

## Regression and release validation

Before correction, the production accepted-socket setup was tested after the
child was explicitly set to TCP_NODELAY=0. It left the observed value at 0,
failing the expected-1 assertion. Starting from 0 prevents default listener
inheritance from hiding the error. The old client also failed with Permission
denied for explicit 1 and default mode.

After correction, the selected tests passed. The client checks 1/2/3/4/8 loops
with explicit 0, plus explicit 1 and absent/default configuration with four
loops; every subprocess verifies requested/observed TCP values, completed
requests, body count, latency count and actual loop distribution.

Full Swift 6.4/Linux release validation passed: 454 XCTest tests (8 diagnostic
skips), 102 Swift Testing tests, zero failures. All five release products built:
example, framework benchmark server, raw NIO benchmark server, benchmark client,
and runtime benchmark server. Corrected Tier 1, stock and raw real-network smoke
also completed at verified client values 0 and 1 with four actual client loops.
Smoke timings are not comparative performance evidence.

## Diagnostic follow-up

A separate six-round root c256 diagnostic completed on corrected Tier 1, stock
and raw NIO, with actual client TCP_NODELAY 0/1, 50,000 warm-up requests and
500,000 measured requests per sample, latency enabled. Both socket-setting order
and server order reversed between rounds. All 36 samples completed (18 million
measured requests), with expected request/body/latency counts, zero child exit
errors, four observed client loops and the requested socket value on every
connection. Preflight status, headers and bodies matched across all three
controls. Servers used two loops on guest CPUs 0–3; client used four loops on
CPUs 4–7. Release Swift 6.4 / NIO 2.104.0, Linux aarch64 VM on Apple M1 Pro.

Medians of six rounds; latency is microseconds. RPS here is **latency-enabled**,
not primary throughput-only RPS:

| Control | Actual client TCP_NODELAY | RPS with latency | p99 | p99.999 | maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| tier1 | 0 | 258,277 | 2,562 | 6,716 | 6,766 |
| tier1 | 1 | 251,692 | 3,250 | 10,877 | 10,903 |
| stock | 0 | 183,484 | 3,348 | 7,629 | 8,415 |
| stock | 1 | 179,832 | 3,530 | 9,144 | 9,761 |
| raw | 0 | 189,451 | 3,688 | 11,044 | 11,160 |
| raw | 1 | 189,020 | 3,601 | 9,429 | 9,446 |

This is a selected transport diagnostic, not the required full concurrency/route
matrix or an external-framework comparison. It does not support an overall
performance win. Actual 0/1 both show tail variation. At default actual 1,
Tier 1 has lower p99 but higher median p99.999 than the two controls in this
sample; the remaining extreme-tail gate is not closed. Historical/new generator
results must not be mixed, and corrected flag 0 must not be equated with the old
flag-0 label. Future baselines need all routes/concurrencies and responder modes.

All samples recorded zero TCP retransmissions and zero cgroup CPU throttling or
memory-limit/OOM events. The client process envelopes still recorded about
3,247–3,252 minor faults and up to 26 major faults per process. The `/bin/true`
wrapper controls had zero major faults after warm-up; this does not locate client
faults within the timed request phase. Involuntary context switches and server
run-queue wait also vary. These aggregates narrow the next diagnostic questions
but do not explain an individual latency spike. The next isolated probe is to
compare the identical client binary on the host bind mount versus container-local
storage; any timing conclusion must be measured, not inferred from fault counts.

Full samples, per-round ranges, source/binary hashes, client rusage, server
scheduler/TCP/cgroup deltas, wrapper source and validation are in the
[machine-readable record](benchmark-data/socket-options-2026-10-18.json).

The diagnostic uses an external Swift `posix_spawn`/`wait4` wrapper for client
CPU, page faults, context switches and peak RSS. It also snapshots server thread
scheduler counters, TCP counters and cgroup pressure outside the client's
internal timer. These resource envelopes include startup/export/cleanup and
are not pure per-request counters; aggregate correlations do not prove the cause
of an individual tail event. This shared-host VM still cannot exclude host
scheduling delays. No source edits/builds run during measured samples.

Local artifacts and external tools are under `/tmp/wt-linux/tail-diagnosis/`.
The initial aborted smoke is preserved separately from corrected smoke and
measured output. No non-Swift implementation source was added to the repository.
