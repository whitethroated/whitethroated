# Custom HTTP/1 transport diagnostic — 2026-10-18

## Scope

This experiment isolates the server-side cost of SwiftNIO's `NIOHTTP1`
parser/encoder path against a benchmark-only WhiteThroated HTTP/1.1 transport
that keeps `NIOCore` and `NIOPosix` but parses request bytes and emits
response bytes directly.

This is diagnostic evidence only. The run used a GitHub-hosted virtualized
runner, so the absolute values and deltas must not be published as a
performance claim.

## Environment

- Date: 2026-10-18
- Host: GitHub-hosted `ubuntu-24.04` runner, Azure westus
- Container: `swift:6.4.0-noble`
- Swift: 6.4.0
- SwiftNIO: exactly 2.104.0
- Architecture: x86_64 Linux
- Server event-loop threads: 2
- Client event-loop threads: 2
- Connections: 64
- Measured requests per sample: 75,000
- Warm-up requests per route/server: 7,500
- Rounds: 3
- Order: alternated raw/custom by round
- Client TCP_NODELAY: disabled for both controls because the hosted container
  rejects the relevant `setsockopt` call with EPERM
- Load model: closed loop, one request in flight per connection

Correctness gate before measurement:

- `BenchmarkHTTP1ExperimentTests`: pass
- raw NIO server release build: pass
- custom HTTP/1 server release build: pass
- benchmark client release build: pass
- diagnostic runner release build: pass

## Median results

| Route | Metric | Raw NIOHTTP1 | Custom HTTP/1 | Custom delta |
|---|---:|---:|---:|---:|
| `GET /` | RPS | 35,470 | 34,457 | -2.86% |
| `GET /` | p50 | 1,664.436 µs | 1,870.021 µs | +12.35% |
| `GET /` | p90 | 3,021.738 µs | 1,940.303 µs | -35.79% |
| `GET /` | p99 | 3,559.414 µs | 3,193.418 µs | -10.28% |
| `GET /json` | RPS | 33,610 | 30,550 | -9.10% |
| `GET /json` | p50 | 1,810.359 µs | 2,025.332 µs | +11.87% |
| `GET /json` | p90 | 3,270.593 µs | 2,080.736 µs | -36.38% |
| `GET /json` | p99 | 4,157.623 µs | 3,926.922 µs | -5.55% |
| `GET /user/42` | RPS | 32,525 | 32,212 | -0.96% |
| `GET /user/42` | p50 | 1,785.374 µs | 1,971.591 µs | +10.43% |
| `GET /user/42` | p90 | 3,293.266 µs | 2,056.150 µs | -37.57% |
| `GET /user/42` | p99 | 4,183.427 µs | 3,862.340 µs | -7.68% |

Lower latency is better. Positive RPS delta is better.

## Verdict

The first custom transport is **not a Pareto win**.

It consistently improves the measured tail shape on this diagnostic host:

- p90 improves by about 36–38% on all three routes.
- p99 improves by about 6–10%.

But it pays for that with:

- p50 regression of about 10–12%.
- throughput regression from about 1% on the parameter route to about 9% on
  the small-JSON route.

Therefore the current implementation must not replace `NIOHTTP1` in the
production runtime.

The useful signal is narrower: removing the generic HTTP/1 parser/encoder
pipeline materially changes the latency distribution and may offer a path to a
more stable tail, but the first byte-oriented implementation still has too much
central-path cost.

## Likely cost centers to test next

Do not infer causality from this hosted-runner result alone. The next controlled
experiments should isolate these candidates one at a time:

1. **Parser scan cost.** The current parser rescans the readable bytes for
   `CRLFCRLF`, then scans the request line and every header. Add incremental
   parser cursor state across reads so an ordinary complete benchmark request
   is parsed in one forward pass.
2. **Temporary closure in route dispatch.** `respond` currently creates a
   local closure around target matching. Replace it with a direct helper using
   the readable target slice and remeasure ARC/codegen effects.
3. **Target slice and dynamic parameter path.** Avoid creating a
   `ByteBuffer.getSlice` solely to perform static path matching; match against
   the original readable request buffer and create a body slice only for the
   dynamic parameter response.
4. **Flush behavior.** The custom path emits one raw response buffer with one
   `writeAndFlush`; raw NIOHTTP1 emits typed response parts through the
   encoder. Measure write versus flush behavior separately before attributing
   the tail improvement to parsing.
5. **Prepared wire storage locality.** Move immutable response bytes to
   connection-independent setup storage only if profiling shows per-connection
   response storage harms cache locality or memory.

## Promotion gate

A custom HTTP/1 transport should advance beyond benchmark-only status only if a
dedicated Linux host with pinned CPU resources shows all of the following at
c64/c256/c512:

- throughput is neutral or better than the matched raw-NIOHTTP1 control;
- p50 is neutral or better;
- p90 and p99 remain better or neutral;
- peak RSS does not materially regress;
- results survive at least five alternating rounds;
- parser adversarial tests cover request smuggling ambiguity, duplicate
  framing, fragmented input, pipelining, body limits, connection semantics,
  chunked transfer encoding, Expect/100-continue, and HTTP/1.0 behavior.

Until those gates pass, this remains an isolation experiment rather than a
runtime design decision.
