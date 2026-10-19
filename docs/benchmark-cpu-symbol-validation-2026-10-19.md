# CPU profile symbol validation — 2026-10-19

**Independent checks validate the named subset of the CPU profile. Unknown
addresses remain unknown; this is not a new performance win or a tail diagnosis.**
The three [instrumented captures](benchmark-executable-placement-2026-10-18.md)
contain 4,722 samples over two million root requests per control at c256. Native
Swift 6.4 / NIO 2.104.0 ELF bytes are unchanged; gperftools 2.15 sampled at 100 Hz
in separate diagnostic processes, with two server loops and four client loops,
actual client TCP_NODELAY=1. No new load or source change was needed here.

## Independent method

The external validator reads weighted stacks directly from the documented
[legacy profile format](https://gperftools.github.io/gperftools/cpuprofile-fileformat.html),
checks the header/trailer, and recovers the executable mappings. It derives ELF
load bias from executable PT_LOAD segments and matches PCs only inside nonzero
symbol-size ranges exported by `nm -S`, including dynamic symbols. Caller return
PCs are adjusted by one byte before range lookup. It never guesses the nearest
preceding symbol when an address lacks a matching range. Aliases remain in the
machine-readable output. Demangling is presentation only and does not determine
sample counts.

The four inspected images are the framework benchmark ELF, raw benchmark ELF,
libc and libswiftCore from the same container as capture. Module hashes and
program-header/symbol exports are preserved in the local archive. Every decoded
sample total matches the native sampler log and the legacy analyzer total.

| Control | Weighted samples | Flat samples with exact sized-symbol coverage | Coverage | Unknown flat samples |
| --- | ---: | ---: | ---: | ---: |
| tier1 | 1,242 | 1,184 | 95.3% | 58 |
| stock | 1,846 | 1,730 | 93.7% | 116 |
| raw | 1,634 | 1,551 | 94.9% | 83 |

The validator also reproduces both flat and cumulative counts for 17 selected
anchors (34 equalities) against pprof. These include write/read, Swift
retain/release in all controls and Tier 1 request/writer/storage helpers. This
supports those names/counts despite the older analyzer's ELF autodetection and
ARM64 `_fini` fallback warnings. It does not validate every legacy source-line
annotation or nearest-symbol placeholder such as `_init@...`.

## Verified coarse findings

Flat sampled-PC counts, with shares of each capture:

| Control | libc write wrapper | libc read wrapper | Swift retain + release |
| --- | ---: | ---: | ---: |
| tier1 | 495 (39.9%) | 128 (10.3%) | 90 (7.2%) |
| stock | 555 (30.1%) | 184 (10.0%) | 215 (11.6%) |
| raw | 510 (31.2%) | 153 (9.4%) | 167 (10.2%) |

The read/write wrapper regions dominate these samples. CPU sampling can charge
kernel work at a syscall wrapper PC; these numbers do not separate kernel work
from pure userspace implementation cost. Relative shares across captures are
not native per-request timings or a throughput comparison.

Tier 1 `writePreparedFast` has 683 cumulative samples (55.0%), including the
write path; that is not 55% framework overhead. `beginRequest` has 785 cumulative
samples (63.2%). Parent/callee shares overlap and cannot be added. The private
`WTHTTP1RequestHead.storageSlice` helper has 8 flat and 56 cumulative samples
(4.5% cumulative), independently matched to sized ELF symbols.

Source inspection identifies concrete request-time materialization in that
helper: it copies a ByteBuffer view into an owned `[UInt8]`. Method, URI and
header byte accessors call it; runtime head conversion consumes these arrays
when decoding Strings, and the minimal Host guard also requests an owned name
array. A retained ByteBuffer head does not make those accessors allocation-free.
The profiler does not count allocations, and caller-side destruction can fall
outside the helper's cumulative samples, so 4.5% is not a complete allocation-tax
estimate or a promised optimization ceiling.

## Next isolated hypothesis

Investigate scoped read-only byte views at the HTTP1/runtime boundary to avoid
selected temporary arrays while preserving the public owned-array accessors.
Keep route-cache keys owned and keyed by exact method/URI; do not retain an
entire mutable request buffer through a cached slice. Required proof includes
nonzero reader indices, empty/large ranges, ByteBuffer COW and view lifetime,
method/header/URI semantics, cache hits/misses/invalidation, framing/security
fallbacks and equivalent String decoding. Do not add unsafe ownership or an
inlining attribute just because a helper appears in a profile.

This is a measured cost-center hypothesis, not implemented behavior or a claim
of future speed. The previous prepared-head deferral remains rejected. Any new
runtime candidate still needs correctness, release builds, repeated native A/B,
raw control and independent concurrency/tail/memory gates with the corrected
client. These on-CPU samples do not establish the cause of off-CPU or VM stalls.
The full corrected responder/route/concurrency and external comparisons remain
open; the overall performance goal is not achieved.

All counts, aliases, unresolved samples, module hashes, validator fingerprints
and anchor comparisons are in the
[machine-readable record](benchmark-data/cpu-symbol-validation-2026-10-19.json).
External validation scripts, exact symbol exports and raw profiles are locally
under `/tmp/wt-linux/tail-diagnosis/`; the temporary archive is not a permanent
public download. No non-Swift implementation source was added to the repository.
The last unchanged release gate remains 454 XCTest (8 skips), 102 Swift Testing,
zero failures and five release products; this analysis did not rerun those tests.
