# Skill: testing and regression

Use this skill for all non-trivial implementation changes.

## Goal

Tests should prove semantic correctness independently of benchmark results.

## Workflow

1. Run the narrowest relevant tests before editing when practical.
2. Add the new regression or behavior test.
3. Implement the change.
4. Run targeted tests.
5. Run the full release suite.
6. Run relevant benchmark diagnostics separately when needed.

## Determinism

Prefer deterministic assertions.

Avoid:

- sleeps
- wall-clock timing assertions
- unstable ordering assumptions
- network races when EmbeddedChannel can test the behavior directly

Use real network tests only for behavior that cannot be represented faithfully in the embedded transport.

## Fast-path tests

A fast path needs at least:

- successful hit
- fallback
- invalidation/boundary condition
- semantic equivalence to the generic path

For per-connection caches, explicitly alternate request identities to catch stale state.

## Router tests

Cover:

- exact route
- parameter route
- catch-all
- precedence
- different methods
- not found
- percent decoding
- repeated target
- changed target after cache warm-up

## Transport tests

Cover applicable lifecycle events:

- head
- body
- end
- zero body
- chunked body
- keep-alive
- connection close
- write failure
- async completion
- pipelining

## Streaming tests

Cover:

- one chunk
- multiple chunks
- empty stream
- limit boundary
- over-limit
- chunk failure
- end failure
- exactly-once completion
- explicit flush when relevant

## Benchmark tests

Diagnostic benchmark tests must:

- be disabled by default
- use environment flags
- print or record metrics without turning noisy values into CI thresholds
- share semantics with network cases where they are meant to isolate one layer

CI smoke iterations should be large enough to exercise code but are not performance evidence.

## Regression discipline

Never remove or weaken a failing test just to land an optimization.

If behavior intentionally changes, update the test and the public/architecture documentation together, with the reason made explicit.
