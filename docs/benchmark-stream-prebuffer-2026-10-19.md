# Response-stream prebuffer experiment — 2026-10-19

## Decision

Reject and withdraw the diagnostic routes. Reusing setup-time immutable
`ByteBuffer` chunks did not reduce response-stream cost for the benchmark's
6-byte and 7-byte writes. The existing `writeString` routes remain the better
implementation for this payload shape.

## Hypothesis and controls

The raw response-stream lower bound writes two cached buffers, while the
framework benchmark calls `writeString` twice per request. The candidate added
three opt-in framework routes that captured immutable setup-time ByteBuffers
and called `write`/`writeAndFlush`; raw aliases retained identical cached
chunks. Exact HTTP/1.1 headers and the 13-byte body matched across string,
buffer, and raw preflight responses.

The isolated matrix used three alternating rounds, known-length/chunked/flush
modes, 64 and 512 connections, and separate throughput/full-latency phases.
Every sample ran 500,000 requests: 108 samples and 54 million requests total.
No cgroup throttling, OOM, major page fault, TCP timeout, input error, or output
reset occurred. The campaign recorded 10,407 retransmitted segments, primarily
from flush traffic.

## Results

Values are medians of three rounds. Latency is microseconds.

| mode | c | string RPS | buffer RPS | raw RPS | string p99 | buffer p99 | raw p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| known | 64 | 130,394 | 125,891 | 157,047 | 1,033 | 1,097 | 857 |
| known | 512 | 131,040 | 128,710 | 165,037 | 6,222 | 6,747 | 5,626 |
| chunked | 64 | 117,641 | 113,299 | 126,880 | 1,147 | 1,182 | 1,084 |
| chunked | 512 | 120,617 | 116,629 | 133,657 | 6,434 | 6,722 | 6,126 |
| flush | 64 | 96,671 | 94,611 | 108,988 | 1,358 | 1,375 | 1,217 |
| flush | 512 | 95,533 | 92,588 | 111,638 | 7,889 | 7,969 | 7,727 |

Prebuffering lost 1.8–3.7% by median RPS in the stable comparisons and lost in
17 of 18 paired rounds. One known-c64 round had a larger 16.9% excursion, but
removing it does not change the verdict. Median server CPU ticks were higher
for the buffer variant in all six cells, and median p99 was worse in all six.
p99.999 was mixed and does not rescue a candidate that consistently consumes
more CPU and throughput.

The likely explanation is that retaining/copying captured ByteBuffer storage
adds ARC/COW traffic whose cost exceeds allocating and encoding these tiny
strings through SwiftNIO's pooled allocator. This is an inference, not a
source-level causal proof. The result does establish that small-string
conversion is not the measured raw-stream gap's dominant removable cost.

Machine-readable summary data is in
[`benchmark-data/stream-prebuffer-2026-10-19.json`](benchmark-data/stream-prebuffer-2026-10-19.json).
