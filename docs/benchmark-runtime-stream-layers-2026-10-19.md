# Raw/runtime/framework response-stream matrix — 2026-10-19

## Purpose

The earlier raw control established a 15–35% response-stream throughput gap,
but could not locate it. This campaign adds an opt-in
`WhiteThroatedRuntime` server control with the same known-length, chunked, and
explicit-first-chunk-flush routes. It separates raw→runtime transport/runtime
orchestration from runtime→framework routing, public response construction,
and the framework-to-runtime stream bridge.

## Method

Three alternating rounds covered all three servers, all three modes, 64 and
512 connections, and separate throughput/full-latency phases. Each sample ran
500,000 requests: 108 samples and 54 million requests. Servers used two event
loop threads; the verified client used four event loops, one in-flight request
per connection, and TCP_NODELAY=1. Headers, 13-byte bodies, two-write shape,
and flush placement were byte-identical in preflight.

No cgroup throttling, OOM, major page fault, TCP timeout, input error, or output
reset occurred. There were 17,654 retransmitted segments, concentrated in
flush traffic. Tail metrics therefore remain observational rather than a
universal latency claim.

## Results

Values are medians of three rounds; latency is microseconds. CPU is server
ticks for the fixed 500,000-request throughput phase.

| mode | c | raw RPS | runtime RPS | framework RPS | raw p99 | runtime p99 | framework p99 | CPU raw/runtime/framework |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| known | 64 | 157,722 | 144,404 | 129,789 | 846 | 957 | 1,007 | 617 / 682 / 755 |
| known | 512 | 168,141 | 144,440 | 131,890 | 5,726 | 5,537 | 6,357 | 594 / 689 / 755 |
| chunked | 64 | 131,289 | 123,963 | 115,979 | 1,044 | 1,076 | 1,131 | 752 / 792 / 847 |
| chunked | 512 | 131,488 | 123,045 | 118,566 | 6,581 | 6,667 | 7,538 | 752 / 808 / 838 |
| flush | 64 | 110,129 | 103,124 | 95,176 | 1,226 | 1,349 | 1,426 | 897 / 959 / 1,035 |
| flush | 512 | 109,484 | 99,802 | 94,512 | 7,629 | 7,342 | 8,930 | 906 / 996 / 1,056 |

Raw→runtime median throughput loss ranged from 5.6% to 14.1%.
Runtime→framework loss ranged from 3.6% to 10.1%. The ordering
raw > runtime > framework held in 17 of 18 paired rounds; the sole exception
was one flush-c512 round. Server CPU ticks increased in that same order for all
six median cells, supporting a real on-CPU cost split rather than a pure load
generator artifact.

p99 generally follows the throughput/CPU ordering, but known-c512 and
flush-c512 runtime p99 were below raw in this sample. p99.999 was mixed:
several framework medians beat raw while flush-c512 framework was materially
worse. These values do not establish a tail win, especially with retransmitted
flush segments and only three rounds.

## Consequence

The remaining gap is distributed. Runtime work should focus on stream state,
head serialization, chunk emission, and producer completion. Framework work
should focus on per-request `Response.stream` construction and the
`ResponseStream`→`RuntimeResponseStream` bridge. Optimizing only tiny string
encoding or only one layer cannot close the measured deficit.

Machine-readable decision data is in
[`benchmark-data/runtime-stream-layers-2026-10-19.json`](benchmark-data/runtime-stream-layers-2026-10-19.json).
