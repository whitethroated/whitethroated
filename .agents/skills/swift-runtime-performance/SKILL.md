# Skill: Swift runtime performance

Use this skill for request-path allocation, ARC, copy-on-write, String/UTF-8, ByteBuffer, response construction, and specialization work.

## Objective

Reduce request-time CPU, allocations, copies, branches, and reference-count traffic without changing public semantics.

## Method

1. Identify the exact hot path before editing.
2. Separate setup-time cost from request-time cost.
3. List likely cost centers:
   - heap allocation
   - ARC retain/release
   - String creation or transcoding
   - Array/Dictionary growth
   - copy-on-write mutation
   - existential/generic boxing
   - closure capture
   - repeated header construction
   - ByteBuffer copy
   - repeated parsing
4. Change one cost center at a time.
5. Add correctness coverage.
6. Measure in release mode.

## Swift-specific guidance

- Prefer UTF-8 and byte-oriented matching when input already arrives as bytes.
- Avoid constructing String values merely to compare method, path, header, or delimiter bytes.
- Use String only at API boundaries where users need String semantics.
- Reuse immutable storage when Swift COW guarantees later mutation remains isolated.
- Be explicit about whether a value copy is cheap metadata or triggers storage duplication.
- Prefer precomputed setup-time data for immutable routes and responses.
- Avoid transient dictionaries for request fields that can be scanned lazily.
- Avoid repeated small-array creation for canonical short responses.
- Keep reference types only where shared identity or mutation is useful.
- Avoid reference wrappers solely to dodge copying unless measurements show the value copy is expensive.
- Keep structs small on the hot path.
- Treat large enum payload copies as potential costs.

## ByteBuffer rules

- Reuse readable immutable buffers safely when semantics allow.
- Understand reader/writer index effects before sharing buffers.
- Avoid copying body bytes merely to calculate length or inspect a prefix.
- Prefer slices/views when lifetime and mutation rules are clear.
- Do not retain unbounded request buffers after a request completes.

## ARC rules

A class reference in a tight path can create measurable retain/release traffic.

When investigating ARC:

- isolate the reference churn
- compare storage-reference caching versus generic enum/match caching
- do not replace safe ownership with unmanaged pointers unless ordinary ownership is proven to be a bottleneck and safety can be demonstrated

Unsafe ownership optimizations require stronger evidence than ordinary optimizations.

## Inlining and specialization

Do not add optimization attributes by instinct.

Before using aggressive inlining or underscored attributes:

- inspect generated behavior through benchmark evidence
- keep the function small
- verify code-size growth does not damage instruction-cache behavior
- document why the attribute is necessary

Prefer compiler-friendly concrete types over magic attributes.

## Allocation acceptance

For a common prepared or synchronous path, treat new per-request allocations as regressions unless they buy required functionality.

For optional features, pay the cost only when the feature is enabled or used.

## Benchmark pairing

Useful comparisons include:

- prepared vs raw NIO
- synchronous pre-buffered vs dynamic text
- cached head vs rebuilt head
- exact Content-Length vs framing repair
- route cache vs fresh lookup
- generic match cache vs resolved storage/handler cache
- lazy parsing untouched vs first access vs full materialization

Use `benchmark-validation` for publication rules.

## Anti-patterns

Do not:

- optimize debug builds
- infer performance from source aesthetics
- assume fewer lines means fewer allocations
- cache globally if per-connection or setup-time storage is sufficient
- add a lock to protect data that can instead become immutable
- trade protocol correctness for a shorter writer path
