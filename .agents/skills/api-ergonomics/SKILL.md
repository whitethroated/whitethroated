# Skill: API ergonomics

Use this skill for public route APIs, middleware APIs, Request/Response conveniences, route groups, streaming APIs, and developer experience.

## Product goal

WhiteThroated should feel as straightforward as Express.js while remaining idiomatic Swift and exposing explicit performance tiers.

Ergonomics must not erase cost visibility.

## API principles

Prefer APIs that are:

- easy to discover
- explicit about sync vs future vs async work
- composable
- type-safe without excessive generic ceremony
- low boilerplate for common routes
- predictable under overload resolution
- compatible with setup-time precomputation

## Preserve cost tiers

Do not force all handlers through one abstraction if it makes cheap handlers pay expensive costs.

Keep clear support for:

- prepared immutable responses
- synchronous handlers
- NIO future handlers
- async/await handlers
- request streaming
- response streaming

An ergonomic overload is good when it selects the cheapest correct runtime representation.

## Express-inspired behavior

Good inspiration:

- `app.get(...)`
- `app.post(...)`
- route parameters
- grouped prefixes
- middleware composition
- request query/cookie/form helpers
- concise response factories

Do not copy JavaScript semantics that are unnatural or expensive in Swift.

## Hidden-cost rule

A convenience method must not silently cause every request to:

- allocate a Task
- allocate a future
- parse every query
- parse every cookie
- decode the whole body
- build a dictionary
- copy body bytes
- acquire a global lock

Prefer lazy accessors.

## Overloads

When adding overloads:

- ensure call sites remain unambiguous
- avoid generic overload sets that significantly slow compilation
- keep behavior consistent across methods
- test representative call sites
- verify the selected runtime responder type is the intended one

## Naming

Prefer direct names over performance marketing names in the public API.

Internal names may describe fast paths, but public users should choose based on semantics, not microarchitecture.

If two APIs have meaningfully different execution models, make that distinction visible in naming or signature.

## Documentation

Any new public API needs:

- a minimal README example if it is user-facing and significant
- behavior tests
- error semantics
- notes about blocking or concurrency expectations when relevant

Do not promise zero allocation or benchmark superiority in API docs unless the claim is narrowly defined and measured.
