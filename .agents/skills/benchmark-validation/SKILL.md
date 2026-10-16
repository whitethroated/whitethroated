# Skill: benchmark validation

Use this skill for any claim that a code change is faster, lower latency, lower memory, or more scalable.

## Principle

Benchmarking is an experiment. Control variables aggressively.

The desired answer is not "WhiteThroated wins." The desired answer is a reproducible measurement of where time and memory go.

## Validation order

For hot-path work, validate in this order:

1. Correctness tests.
2. In-process diagnostic benchmark for the targeted component.
3. WhiteThroated before/after network benchmark.
4. Raw SwiftNIO control with equivalent semantics.
5. Cross-framework comparison, including Actix Web, only after the Swift-side overhead is understood.

## Release mode only

Performance conclusions require release builds.

Do not use debug timing as evidence.

## Equivalence contract

Compared cases must match:

- HTTP method
- URI shape
- response status
- response payload
- relevant headers
- keep-alive behavior
- HTTP version
- request body semantics
- compression setting
- TLS setting
- worker/thread allocation where comparable
- load generator
- connection count
- warm-up
- duration or request count
- latency sampling mode

If any of these differ, state the difference and do not call the result apples-to-apples.

## Concurrency matrix

For external HTTP comparisons, treat 64, 256, and 512 connections as independent gates unless `BENCHMARKS.md` specifies a task-specific matrix.

Do not optimize only for the single concurrency value that produces the best headline.

## Mandatory metrics

Capture:

- requests/second
- p50 latency
- p90 latency
- p99 latency
- p99.999 latency when available
- maximum latency
- completed requests
- errors/timeouts

For memory-sensitive work also capture peak RSS.

For streaming/payload work also capture response-body throughput.

When profiling, useful counters include:

- CPU cycles
- instructions
- branches
- branch misses
- cache references/misses
- context switches
- migrations
- page faults

## Repetition

One run is not evidence.

Use:

- warm-up
- multiple measured rounds
- alternating or randomized A/B order
- medians as the primary summary
- spread/range inspection for noise

When A/B results overlap ordinary variance, classify the result as neutral.

## Publication gate

Before documenting an optimization as faster:

- tests pass
- benchmark semantics match
- the same machine/environment was used
- multiple rounds support the conclusion
- throughput improvement survives noise
- tail latency is not materially worse
- peak RSS is not materially worse unless explicitly justified
- the result is not caused by changing the control
- the result is not a benchmark-only special case

If only a diagnostic microbenchmark improves but network throughput is neutral, document it as a local cost reduction, not an end-to-end throughput win.

## Raw SwiftNIO control

Raw SwiftNIO is a lower-bound transport control, not an opponent to handicap.

It should:

- return equivalent data
- use fair canonical response construction
- use equivalent head-dispatch timing
- use the same client and socket settings

The key question is the remaining framework tax between raw NIO and WhiteThroated.

## Actix Web comparison

Actix is an external performance reference.

When comparing:

- pin Rust and Actix versions
- record compiler profile/options
- match route behavior
- match HTTP/1.1 semantics
- disable unrelated compression/HTTP2
- use the same hardware and load generator
- record CPU affinity/allocation if controlled

Do not vendor Rust code into this Swift-only repository solely for the comparison.

## CI timing

GitHub-hosted CI proves the benchmark harness still executes.

It does not provide stable hardware and therefore must not be used for published ns/op thresholds or performance regressions.

## Benchmark record template

For a serious result, record:

- commit SHA
- Swift version
- SwiftNIO version
- OS/kernel
- CPU model
- logical/physical cores used
- server workers
- client/load-generator threads
- connection count
- request count or duration
- warm-up
- endpoint
- response bytes
- latency mode
- RPS median and rounds
- latency percentiles
- peak RSS if applicable
- profiler counters if applicable
- exact control version

## Stop conditions

Reject an optimization when:

- correctness changes
- benchmark semantics differ
- improvement is noise
- p99/tail latency materially regresses without a deliberate tradeoff
- memory growth is disproportionate
- complexity increases heavily for negligible benefit
- it only wins because the benchmark became easier
