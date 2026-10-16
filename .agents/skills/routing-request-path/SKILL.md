# Skill: routing and request path

Use this skill for `Router.swift`, route registration, exact lookup, trie fallback, parameters, catch-all routes, route groups, and per-connection route caches.

## Objective

Make route resolution extremely cheap while preserving deterministic semantics.

## Routing hierarchy

Treat route matching as two broad classes:

- exact/static lookup
- structured fallback for parameters and catch-all routes

Fast exact lookup should not make dynamic routing semantics less correct.

## Setup-time work

Prefer setup-time work for:

- route normalization
- prefix composition
- exact-table construction
- trie construction
- parameter-name metadata
- prepared endpoint storage
- route classification

Serving structures should be read-only where practical.

## Route precedence

Preserve the repository's established precedence.

At minimum, verify interactions among:

- exact static routes
- single-segment parameters
- catch-all routes
- methods
- nested route groups

Catch-all captures must remain terminal.

## Parameter handling

Avoid eager String creation.

Prefer:

- byte ranges into the request URI
- lazy percent decoding
- positional parameter access when it avoids a name lookup
- setup-time parameter-name metadata

Parameter ranges are request-target specific. Never reuse them across a changed URI unless the cache key proves identity.

## Per-connection caching

A connection-local cache can exploit keep-alive locality without global synchronization.

A safe cache key must include every request property that determines the cached result.

For route matches this normally includes method + exact URI.

On key mismatch:

- perform normal lookup
- refresh all derived side caches together
- clear stale handler/storage/parameter metadata

Do not cache only by route template when parameter ranges belong to the concrete URI.

## Cache design

Compare cache variants empirically:

- full RouterMatch
- resolved PreparedResponseStorage
- resolved synchronous handler + parameter metadata
- fresh exact lookup

A cache is useful only if validation + retrieval is cheaper than the lookup it replaces.

Remove caches that lose to a fresh lookup or add meaningful memory/branch cost without a demonstrated workload benefit.

## Fast path and fallback equivalence

For every route fast path, test:

- repeated same method + URI
- same URI, different method
- same method, different URI
- parameter value changes
- exact route followed by dynamic route
- dynamic route followed by exact route
- not found
- percent-escaped parameter
- catch-all route

## API changes

Route API ergonomics must not silently add runtime layers.

Route groups should compose prefixes during setup rather than introducing request-time middleware solely for grouping.

Pair public API work with `api-ergonomics`.

## Benchmarking

Use router-only microbenchmarks to isolate lookup cost, then network benchmarks to verify the optimization matters end to end.

Track both hit and miss/fallback behavior. A win on exact static routes that heavily regresses dynamic routing needs an explicit tradeoff decision.
