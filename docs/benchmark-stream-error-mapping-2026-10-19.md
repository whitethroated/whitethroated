# Response-stream error-mapping experiment — 2026-10-19

## Decision

Retain the candidate. It removes the per-write framework `flatMapError` from
successful response-stream writes and instead maps synchronous declared-length
violations before their failed future is created. This is an accepted
throughput/CPU optimization, not evidence of a universal tail-latency win.

## Correctness invariant

- Declared-length overflow/invalid-length failures remain public
  `ResponseStreamError` values.
- Successful writes return the transport's original future.
- Foreign channel and producer failures are not rewritten.
- No Task, lock, or event-loop hop is added.
- Known-length, chunked, and explicit-flush wire responses remain byte-for-byte
  equal to the frozen baseline in preflight checks.

The complete Swift 6.4 Linux release suite passed: 447 XCTest cases passed,
8 opt-in diagnostics skipped, and 102 Swift Testing cases passed. The example,
framework benchmark server, runtime benchmark server, raw NIO server, and
benchmark client all built in release mode. The macOS sandbox build also
exposed and fixed platform-width assumptions in the retained TCP_NODELAY
client/test changes; its only remaining test failures were two socket `bind`
operations denied by the host sandbox.

## Native A/B

The frozen baseline and candidate ran in alternating order for four rounds.
Each of three stream modes ran at 64, 256, and 512 connections with separate
throughput and full-latency phases, 500,000 requests per sample: 144 samples,
72 million measured requests. There was no cgroup throttling or memory
pressure. Values below are medians; latency is microseconds.

| route | c | RPS before | RPS after | p99 before | p99 after | p99.999 before | p99.999 after |
|---|---:|---:|---:|---:|---:|---:|---:|
| known | 64 | 122,539 | 130,978 | 1,152 | 1,037 | 8,208 | 5,454 |
| known | 256 | 122,464 | 131,710 | 4,045 | 4,060 | 11,826 | 13,002 |
| known | 512 | 124,550 | 130,337 | 7,221 | 6,575 | 22,995 | 14,067 |
| chunked | 64 | 112,232 | 116,920 | 1,255 | 1,156 | 6,930 | 5,973 |
| chunked | 256 | 112,859 | 117,464 | 4,600 | 4,401 | 32,989 | 23,978 |
| chunked | 512 | 112,406 | 115,308 | 7,762 | 6,841 | 20,688 | 14,650 |
| flush | 64 | 93,052 | 96,225 | 1,457 | 1,385 | 7,602 | 7,239 |
| flush | 256 | 91,923 | 96,971 | 5,179 | 4,971 | 38,172 | 11,696 |
| flush | 512 | 91,910 | 95,912 | 9,216 | 8,817 | 18,860 | 21,519 |

Throughput improved in all nine cells by 2.6–7.6%. p99 improved in eight;
known c256 was approximately neutral. Two p99.999 cells worsened, so the
candidate required a longer selected-tail confirmation.

## Tail confirmation

Known c256 and flush c512 ran latency-only for six alternating rounds with
2,000,000 requests per sample: 24 samples and 48 million measured requests.

| route | metric | before median | after median | interpretation |
|---|---|---:|---:|---|
| known c256 | p99 | 3,981 us | 4,047 us | +1.7%, within round spread |
| known c256 | p99.999 | 25,659 us | 25,790 us | approximately neutral |
| known c256 | server CPU ticks | 3,174 | 3,020 | -4.8% |
| flush c512 | p99 | 9,145 us | 8,648 us | -5.4% |
| flush c512 | p99.999 | 27,009 us | 29,444 us | +9.0%, noisy/worse |
| flush c512 | server CPU ticks | 4,284 | 4,087 | -4.6% |

There was no throttling, input error, reset, timeout, listen drop, backlog
drop, or TCP memory pressure. The run recorded 63,980 retransmitted segments,
concentrated in the flush workload. Single-round maxima reached 311 ms for
known-after and 114 ms for flush-after; baseline rounds also had large
excursions. Therefore p99.999 is reported as unresolved rather than improved.

## Raw control and profiles

The new opt-in raw SwiftNIO controls use identical HTTP/1.1 response headers,
body bytes, two-write shape, and explicit first-chunk flush. Across 144 samples
and 72 million requests, Tier 1 trailed this cached-head lower bound by roughly
15–35% RPS and had worse p99 in all nine cells. The control deliberately omits
framework routing and prebuilds its heads/chunks, so it identifies remaining
transport/framework room rather than an equivalent implementation cost.

Six 2-million-request userspace CPU profiles resolved 92.0–95.1% of samples.
The differential was distributed among `writev`, malloc/free, ARC retain/release,
response-head scanning, the response writer, and connection lifecycle code;
there was no single dominant cost center. CPU profiles do not explain off-CPU
tail stalls.

Machine-readable decision data is in
[`benchmark-data/stream-error-mapping-2026-10-19.json`](benchmark-data/stream-error-mapping-2026-10-19.json).
