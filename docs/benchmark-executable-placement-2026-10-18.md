# Identical client executable placement — 2026-10-18

**Result: process major faults disappear on container-local storage, but tail
latency does not improve consistently. No runtime change or performance win.**
This tests the filesystem-placement hypothesis raised by the
[socket-option diagnosis](benchmark-socket-options-2026-10-18.md).

## Controlled setup

The corrected client executable was copied from the host bind mount
`/out/tail-diagnosis/corrected-client` to `/tmp/wt-diagnosis-local/client` inside
the container. Both files have the same SHA-256; `ldd` resolves the same shared
library paths. `stat -f` reports `fuseblk` for the bind file and `overlayfs` for
the local copy. Source, server binaries, wrapper, requested workload and socket
settings remain fixed. Servers and diagnostic output stay on the bind mount in
both arms; this is not a test of moving every artifact into local storage.

Release Swift 6.4, NIO 2.104.0, Linux aarch64 Docker on Apple M1 Pro. Servers use
two event loops on guest CPUs 0–3, client four observed loops on guest CPUs 4–7.
GET `/`, HTTP/1.1 keep-alive, 256 connections, actual client TCP_NODELAY=1
verified on every socket before measurement. No TLS/compression. The framework
runs Tier 1 or stock; raw NIO is the equivalent lower-bound control.

Six rounds reverse both server and placement order. Each cell gets 50,000
warm-up requests then 500,000 measured requests with latency enabled. All 36
samples completed (18 million measured requests), expected zero body bytes,
499,744 latency samples, four client loops and matching TCP setting. Preflight
status, headers and bodies matched across the three server controls. Source
and binary fingerprints are preserved in the
[machine-readable record](benchmark-data/executable-placement-2026-10-18.json).
No source edits, builds or other tests ran during measurement.

## Results

Medians of six rounds; latency is microseconds. RPS is latency-enabled,
not the primary throughput-only metric:

| Control | Client placement | RPS with latency | p99 | p99.999 | maximum | Process major faults |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| tier1 | bind | 255,832 | 2,711 | 9,542 | 9,754 | 26 |
| tier1 | local | 254,570 | 3,097 | 12,181 | 12,723 | 0 |
| stock | bind | 186,719 | 3,597 | 10,935 | 11,757 | 26 |
| stock | local | 188,882 | 3,413 | 11,421 | 11,580 | 0 |
| raw | bind | 189,206 | 3,528 | 11,143 | 11,177 | 26 |
| raw | local | 190,036 | 3,475 | 10,894 | 11,410 | 0 |

Every bind-mounted client process recorded 26 major faults; every local client
recorded zero. Nevertheless Tier 1 median p99.999 increased about 28%, while
stock and raw were mixed/close. Tier 1 latency-enabled RPS changed about -0.5%,
stock +1.2%, raw +0.4%: no stable end-to-end throughput improvement is established.
The local Tier 1 arm also contains a 64.5 ms p99.999 round. No outliers were
removed. These observations reject the simple claim that removing those process
major faults solves the tail issue.

Counters cover the whole client process, including startup, sorting/export and
cleanup. They do not identify faults inside the request timer. Both arms also
have minor faults and context switches. Server scheduler counters and TCP/cgroup
deltas are retained. There were zero TCP retransmissions and zero cgroup CPU
throttling events; these facts do not exclude host/VM scheduling delays.

## Interpretation and next evidence

The fault-count difference is real for these executable placements. Its causal
connection to request tails is unproven. Local execution alone should not be
presented as a framework optimization, and these selected cells do not satisfy
the full concurrency/route/responder or external-framework goal. The next step
is to check usable CPU/scheduler profiling rather than make another speculative
runtime edit. An event-aligned trace would be stronger than per-process totals.

The last release correctness gate remains the socket-fix state: 454 XCTest
(8 diagnostic skips), 102 Swift Testing, zero failures, and five release products.
No production or test source changed in this experiment; the existing source
fingerprints are checked again rather than rerunning unchanged tests for timing.
Local raw logs/scripts are under `/tmp/wt-linux/tail-diagnosis/executable-placement/`.
The JSON preserves all measured rounds, wrapper resources, scheduler/TCP/cgroup
counters, hashes and resolved libraries. The temporary archive is not a public
permanent download. No non-Swift implementation source was added to the repo.


## Profiling availability follow-up

The installed environment had no usable perf/strace binaries. A simulated apt
installation would upgrade a package, so tools and needed libraries were instead
downloaded/extracted under `/tmp/wt-profiler`, without installing packages or
changing the runtime baseline, kernel settings, seccomp or capabilities.
The perf software `task-clock:u` probe failed with “No permission to enable”
(exit 255); strace on an owned `/bin/true` child succeeded. This is a container
profiling constraint, not an approval rejection or an HTTP runtime failure.

An alternative CPU sampler works: gperftools 2.15 `libprofiler`, loaded only in
separate diagnostic server processes. Sampling is toggled after warm-up and
stopped before terminating each server, using `CPUPROFILESIGNAL=12` at the default
100 Hz. This follows the [official CPU-profiler documentation](https://gperftools.github.io/gperftools/cpuprofile.html).
No source/relinking or persistent library-path change was made. These processes
use the private profiler library path and preload, so their timing is not an
uninstrumented benchmark result. Client remains the identical local binary,
actual TCP_NODELAY=1, four loops; each two-loop server handles two million root
requests at c256 after a 50,000-request unprofiled warm-up.

| Capture | Completed load requests | CPU samples |
| --- | ---: | ---: |
| Tier 1 | 2,000,000 | 1,242 |
| stock NIO | 2,000,000 | 1,846 |
| raw NIO | 2,000,000 | 1,634 |

All loads completed with expected zero body bytes and observed client settings.
The 4,722 samples are available for cost investigation. They are **not yet a
validated quantitative function-cost report**: the packaged legacy Perl pprof
warns about ELF type detection and ARM64 address parsing; some stripped-library
labels can also be nearest-symbol approximations. Raw profile hashes, sampler
logs, provisional flat/cumulative text and warnings are preserved in the JSON.
Validate symbolization independently before choosing an optimization from them.
On-CPU samples alone also cannot explain off-CPU or VM scheduling stalls.

Capture artifacts are under `/tmp/wt-linux/tail-diagnosis/cpu-profiles/`;
external scripts/tools stay outside the Swift-only repository. The next action
is validating the analysis path, then inspecting the affected request path with
that evidence. The full external-framework and corrected baseline gates remain
open; no previous rejected runtime optimization was reintroduced.
