# WhiteThroated Agent Guide

This file is the canonical instruction set for coding agents working in this repository.

WhiteThroated is an experimental high-performance web framework written entirely in Swift. Its two product goals are:

1. Express.js-level ergonomics for application developers.
2. Runtime overhead low enough to compete with the fastest practical server frameworks, with Actix Web as an external performance reference and raw SwiftNIO as the lower-bound control.

Performance ambition never overrides correctness or benchmark integrity. Never claim a win that has not been measured under equivalent conditions.

## Instruction precedence

When instructions conflict, use this order:

1. The user's explicit request.
2. The closest scoped `AGENTS.md`.
3. This root `AGENTS.md`.
4. `ARCHITECTURE.md`.
5. `BENCHMARKS.md`.
6. Existing tests and established local conventions.
7. README examples and public documentation.

If an implementation would violate an architecture invariant, change the invariant only with explicit correctness evidence and benchmark evidence.

## Required reading

Before modifying runtime code, read:

- `ARCHITECTURE.md`
- the relevant source files
- nearby tests
- the relevant skill under `.agents/skills/`

Before modifying performance-sensitive code, also read:

- `BENCHMARKS.md`
- `.agents/skills/benchmark-validation/SKILL.md`
- `.agents/skills/swift-runtime-performance/SKILL.md`
- `.agents/skills/swiftnio-http-runtime/SKILL.md` when transport or event-loop behavior is involved

Before changing public API design, also read:

- README examples
- `.agents/skills/api-ergonomics/SKILL.md`

## Repository map

- `Sources/WhiteThroated/` — framework API: Application, Router, middleware, Request/Response.
- `Sources/WhiteThroatedRuntime/` — internal runtime: bootstrap, HTTP/1.1 pipeline, dispatch, response writer.
- `Sources/WhiteThroatedExample/` — minimal usage example.
- `Tests/WhiteThroatedTests/` — framework correctness, transport, regression, and diagnostic benchmark tests.
- `Tests/WhiteThroatedRuntimeTests/` — runtime-level connection/writer/streaming tests.
- `Benchmarks/WhiteThroatedBenchmarkServer/` — framework benchmark server.
- `Benchmarks/WhiteThroatedRuntimeBenchmarkServer/` — runtime-level benchmark server (no framework types).
- `Benchmarks/RawNIOBenchmarkServer/` — raw SwiftNIO control.
- `Benchmarks/WhiteThroatedBenchmarkClient/` — Swift benchmark client.
- `ARCHITECTURE.md` — runtime invariants.
- `BENCHMARKS.md` — benchmark methodology and commands.
- `.github/workflows/ci.yml` — release-mode CI validation.

## Non-negotiable repository constraints

- Runtime source, tests, examples, and benchmark programs must be Swift.
- Do not add Python, JavaScript, TypeScript, Rust, C, C++, or shell source files to implement or benchmark WhiteThroated.
- External profilers and external benchmark harnesses may be used outside the repository.
- Keep SwiftNIO pinned unless a dependency upgrade is the explicit task and has its own validation.
- Do not add a dependency for functionality that can be implemented clearly and efficiently with Swift, the standard library, or the already-pinned SwiftNIO modules.
- Do not hide performance regressions behind API convenience.
- Do not weaken HTTP correctness, header validation, body limits, proxy trust, or event-loop safety to gain benchmark numbers.
- Do not optimize by special-casing a public benchmark request in a way real applications cannot use.

## Toolchain

Development and benchmark target:

- Swift 6.4
- Swift Package Manager tools version 6.1+
- SwiftNIO 2.104.0, pinned exactly

Primary validation commands:

```text
swift test -c release
swift build -c release --product whitethroated-example
swift build -c release --product whitethroated-benchmark-server
swift build -c release --product raw-nio-benchmark-server
swift build -c release --product whitethroated-benchmark-client
```

Use release mode for performance conclusions. Debug-mode timing is not performance evidence.

## Agent operating protocol

### 1. Inspect before editing

Trace the full request path that is affected. Identify:

- setup-time work
- per-connection state
- per-request state
- allocations and copies
- event-loop hops
- future or Task creation
- HTTP framing work
- route lookup work
- response serialization work

Do not patch a hot-path symptom before locating its cost center.

### 2. Define the invariant

Before a non-trivial change, state internally what must remain true. Typical invariants include:

- route precedence remains unchanged
- no stale per-connection cache crosses method or URI boundaries
- prepared routes remain request-object free
- synchronous handlers remain Task-free and future-free
- event-loop-confined mutable state stays on its channel event loop
- response framing remains RFC-correct
- body limits are enforced before unbounded accumulation
- public semantics remain identical across optimized and fallback paths

### 3. Make the smallest coherent change

Prefer a narrow optimization that isolates one cost. Avoid unrelated refactors in a performance patch.

If a refactor is needed before an optimization, keep the refactor behavior-preserving and validate it separately.

### 4. Add or update correctness coverage

Every bug fix needs a regression test.

Every new fast path needs tests for:

- hit path
- miss/fallback path
- boundary conditions
- invalidation conditions
- equivalent semantics to the generic path

### 5. Benchmark when the hot path changes

A performance-sensitive change is incomplete until measured against a relevant baseline. Follow the benchmark skill and `BENCHMARKS.md`.

### 6. Update documentation only after behavior is real

README, architecture, and benchmark claims must describe code that exists and measurements that were actually run.

## Runtime architecture invariants

WhiteThroated separates setup from serving. Application configuration is mutable before start and frozen after serving begins.

Protect these design properties:

- routing structures are setup-mutable and serving-read-only
- prepared responses perform expensive work during setup
- synchronous routes stay synchronous
- NIO-future routes stay event-loop-native
- async/await is opt-in and pays Task cost only when explicitly used
- middleware-free paths do not pay middleware costs
- streaming features do not tax unrelated methods or routes
- request conveniences should be lazy where practical
- public abstractions must not force unnecessary hot-path materialization

Do not flatten distinct responder types into one generic async abstraction if that makes cheaper paths pay more.

Respect the framework/runtime module boundary: `WhiteThroated` owns developer-facing behavior and depends on `WhiteThroatedRuntime`; the runtime owns HTTP execution on SwiftNIO and must not gain framework concepts (route registration, middleware composition, convenience APIs). Keep the `RuntimeDispatcher` bridge a concrete struct of closures — no protocols, existentials, or per-request allocations. Users import only `WhiteThroated`.

## Swift performance rules

On hot paths:

- Prefer direct byte-oriented work over unnecessary String materialization.
- Prefer `ByteBuffer` and UTF-8 views when data is already bytes.
- Avoid temporary arrays, dictionaries, closures, boxes, and generic wrappers unless measured negligible.
- Understand copy-on-write behavior before mutating arrays, strings, headers, or buffers.
- Avoid repeated header reconstruction when immutable canonical storage can safely be reused.
- Avoid ARC traffic from needless reference churn.
- Do not add `@inline(__always)`, `@_transparent`, unsafe pointers, or unchecked isolation as superstition. Require a demonstrated benefit and a documented invariant.
- Keep setup-time precomputation aggressive when it removes request-time work without exploding memory use.
- Prefer specialized fast paths with a correct general fallback when the specialization is common and measurable.

See `.agents/skills/swift-runtime-performance/SKILL.md`.

## SwiftNIO and concurrency rules

- Never block an event-loop thread.
- Never call synchronous waiting APIs on an event loop.
- Keep request-local transport work on the channel event loop whenever possible.
- Do not create a Swift Task per request on prepared, synchronous, or NIO-future routes.
- Use `EventLoopFuture` for event-loop-native asynchronous I/O.
- Only hop futures when ownership requires it.
- Do not introduce locks into the ordinary request path without hard evidence they are unavoidable.
- Channel handler mutable state must remain event-loop confined.
- Treat `@unchecked Sendable` and unsafe isolation as proof obligations, not convenience annotations.
- Preserve backpressure and streaming semantics.

See `.agents/skills/swiftnio-http-runtime/SKILL.md`.

## Router and request-path rules

Route behavior must remain deterministic.

Preserve:

- exact/static precedence
- parameter route semantics
- catch-all terminal behavior
- method separation
- percent-decoding correctness
- exact cache invalidation by request identity where required

Per-connection caches are allowed only when their key proves the cached object is valid for the current request. Never reuse parameter ranges, handlers, or prepared storage across a method/URI change unless the cache key explicitly makes that safe.

Prefer setup-time route compilation and read-only serving structures.

See `.agents/skills/routing-request-path/SKILL.md`.

## HTTP correctness and security

Fast paths must produce the same wire semantics as generic paths.

Always consider:

- HTTP method semantics
- keep-alive and Connection handling
- Content-Length normalization
- Transfer-Encoding
- HEAD/body suppression
- 1xx/204/304 body restrictions
- conditional requests and entity tags
- byte ranges
- malformed headers
- request smuggling ambiguity
- CR/LF response-splitting defense
- declared body limits
- streaming limits
- trusted proxy boundaries

Do not bypass SwiftNIO response-header validation.

See `.agents/skills/http-correctness-security/SKILL.md`.

## Public API design

The public API should feel small, discoverable, and Swift-native while retaining Express-like productivity.

Prefer:

- obvious route registration
- route groups that compile away request-time overhead
- synchronous APIs for synchronous work
- explicit future APIs for NIO-native work
- explicit async/await APIs for structured-concurrency work
- prepared-response APIs for immutable content
- lazy request parsing
- escape hatches to NIO primitives when advanced users need them

Avoid APIs that look simple but silently add a Task, future, lock, full-body copy, JSON re-encoding, dictionary materialization, or global synchronization to every request.

See `.agents/skills/api-ergonomics/SKILL.md`.

## Testing policy

Use the existing Swift test style and nearby helpers.

Minimum expectations:

- run targeted tests while iterating
- run `swift test -c release` before considering a change complete
- test both optimized and fallback behavior
- test malformed and adversarial HTTP input when transport semantics change
- add regression coverage for previously failing behavior
- keep benchmark tests opt-in when they are diagnostic rather than deterministic correctness checks

Do not convert noisy timing data into unit-test pass/fail thresholds on shared CI runners.

See `.agents/skills/testing-regression/SKILL.md`.

## Benchmark policy

The benchmark goal is to find real framework overhead, not to manufacture a leaderboard number.

Use this control hierarchy:

1. Same WhiteThroated path before vs after the change.
2. Equivalent raw SwiftNIO control.
3. Equivalent WhiteThroated responder modes.
4. External Actix Web comparison only after Swift-side overhead is understood.

Mandatory external framework comparisons must match:

- request method and path shape
- response status
- response body
- relevant headers
- HTTP version
- keep-alive behavior
- concurrency
- worker/thread count where comparable
- machine and CPU allocation
- warm-up
- duration or request count
- load generator
- latency collection mode

Primary metrics:

- requests/second
- p50 latency
- p90 latency
- p99 latency
- p99.999 latency where the harness provides it
- maximum latency
- CPU utilization or CPU time
- peak RSS for memory-sensitive work
- response/body throughput for streaming or payload work

Diagnostic metrics when useful:

- ns/op in process
- instructions
- cycles
- branch misses
- cache misses
- context switches
- page faults

Never publish GitHub-hosted-runner ns/op as a performance claim.

A change is not a win if peak throughput increases while an important concurrency level or tail-latency profile regresses materially without an explicit tradeoff decision.

See `.agents/skills/benchmark-validation/SKILL.md` and `BENCHMARKS.md`.

## Performance acceptance checklist

For a hot-path optimization, require all applicable items:

- correctness tests pass
- release build passes
- benchmark semantics are identical
- before/after measurements use the same environment
- multiple measured rounds are used
- measurement order is alternated or randomized when drift can bias results
- median results improve or remain neutral
- tail latency does not materially regress
- memory does not materially regress unless explicitly justified
- raw SwiftNIO gap is reduced or the remaining cost is identified
- no special benchmark-only shortcut leaked into production semantics

If the result is within ordinary run-to-run noise, call it neutral, not faster.

## Documentation rules

Update `ARCHITECTURE.md` when an invariant or runtime path changes.

Update `BENCHMARKS.md` when:

- a benchmark case changes
- a control changes
- a new metric becomes mandatory
- benchmark interpretation changes

Update `README.md` when public API usage or user-visible capability changes.

Do not put speculative performance claims in README.

## Dependency policy

New dependencies are exceptional.

Before adding one, verify:

- the functionality cannot reasonably live in WhiteThroated or SwiftNIO
- it does not impose runtime work on unrelated features
- it supports the Swift toolchain and platforms
- it does not compromise reproducibility
- its allocation, concurrency, and transitive dependency costs are understood

Benchmark-affecting dependency updates require fresh baselines.

## Change discipline

Keep commits conceptually focused.

Do not:

- mix formatting churn with a hot-path optimization
- rewrite unrelated files
- change benchmark controls and production code in a way that makes attribution impossible
- delete tests because an optimization breaks them
- weaken assertions to make a patch pass
- silently change response semantics to gain throughput

## Definition of done

A task is complete only when all applicable items are true:

- implementation is finished
- targeted tests pass
- release test suite passes
- relevant release products build
- public behavior has coverage
- hot-path changes have benchmark evidence
- architecture/benchmark/API docs are updated when needed
- no non-Swift implementation source was added
- the final report clearly separates measured facts from hypotheses

## Skills

Read only the skills relevant to the task, but do not skip the benchmark skill for performance work.

- `.agents/skills/swift-runtime-performance/SKILL.md` — ARC, COW, allocation, String/UTF-8, ByteBuffer, specialization.
- `.agents/skills/swiftnio-http-runtime/SKILL.md` — event loops, futures, ChannelHandlers, transport lifecycle, streaming.
- `.agents/skills/routing-request-path/SKILL.md` — route tables, trie fallback, parameter capture, per-connection caches.
- `.agents/skills/benchmark-validation/SKILL.md` — controlled measurement and publication gates.
- `.agents/skills/api-ergonomics/SKILL.md` — Express-inspired Swift API without hidden runtime tax.
- `.agents/skills/http-correctness-security/SKILL.md` — HTTP framing, validation, smuggling resistance, proxy trust.
- `.agents/skills/testing-regression/SKILL.md` — correctness and regression strategy.

When more than one skill applies, use all of them. Performance work commonly requires at least runtime-performance + benchmark-validation, and transport work normally also requires swiftnio-http-runtime + http-correctness-security.
