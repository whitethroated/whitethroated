# Skill: modular battery design

Use this skill whenever adding, changing, splitting, or integrating an optional
WhiteThroated product or application capability.

Typical scope includes CORS, static files, validation, rate limiting,
observability, lifecycle, authentication, sessions, CSRF, services, database
adapters, compression, TLS, WebSocket, OpenAPI, and future optional modules.

## Principle

WhiteThroated is "batteries available", not "batteries always running".

A capability that an application does not import, configure, or install must not
silently add request-time work to the core framework.

Optional modules may depend on WhiteThroated. The WhiteThroated core and runtime
must not depend on optional application modules.

Preserve this dependency direction:

```text
optional application module
        |
        v
WhiteThroated
        |
        v
WhiteThroatedRuntime
        |
        v
WhiteThroatedHTTP1 / SwiftNIO
```

Do not reverse the graph.

## Core isolation

An optional module must not leak application concepts into the runtime.

Do not add concepts such as:

- user identity;
- session state;
- ORM models;
- database pools;
- validation schemas;
- OpenAPI metadata;
- tracing spans;
- static-file roots;
- TLS certificate ownership;
- WebSocket route registries;

to `WhiteThroatedRuntime` merely to make an optional feature easier to build.

If multiple modules genuinely need a core hook, the hook must be narrowly
defined and justified independently from any one module.

A new core hook should normally be:

- configured at setup time;
- immutable while serving;
- represented by concrete values or closures;
- absent or nil when unused;
- allocation-free on the disabled path where practical;
- free of global service-locator lookups;
- validated with benchmarks when it touches the request path.

## Opt-in means zero hidden activation

Importing or linking a product must not automatically:

- register middleware;
- register routes;
- allocate per-request state;
- create a Task per request;
- create a future per request;
- initialize a connection pool;
- start timers;
- open sockets;
- discover application routes;
- alter request parsing;
- alter response serialization;
- change trusted-proxy behavior;
- change logging or telemetry behavior.

Activation must be explicit in application setup.

If a feature is not installed, unrelated routes should preserve the same
execution model as before.

## Setup-time first

Prefer doing invariant work once during setup:

- validate configuration;
- compile route metadata;
- normalize policies;
- precompute immutable headers;
- build lookup tables;
- validate schema relationships;
- validate operation identifiers;
- construct TLS contexts;
- prepare immutable response representations.

Do not repeat setup work on every request.

When configuration becomes immutable after application start, make that
lifecycle boundary obvious in the API and implementation.

## Disabled, installed-idle, and active states

For optional modules that can affect request-time behavior, reason about three
independent states:

1. product not used;
2. module installed but not active for the current request;
3. module active for the current request.

Do not treat state 2 and state 3 as equivalent.

Performance-sensitive modules should be benchmarked across these states when
practical. The idle-installed state is especially important because middleware
or dispatch hooks can tax unrelated routes even when the feature does no useful
work.

## Product boundaries

Prefer one SwiftPM library product per capability when the feature can be used
independently.

A module should have one primary responsibility and a small dependency surface.

Do not make a low-level capability depend on a higher-level one merely for API
convenience.

Examples of acceptable direction:

- OpenAPI may depend on Validation;
- Redis session storage may depend on the Session contract;
- PostgreSQL may depend on the generic Database contract.

Avoid inverse coupling:

- Validation must not require OpenAPI;
- Sessions must not require Redis;
- Database contracts must not require PostgreSQL;
- WhiteThroated core must not require any of them.

## Provider and adapter model

When a capability needs a backend, separate the contract from the adapter.

Prefer:

```text
application API
    |
    v
small capability contract
    |
    v
optional adapter
    |
    v
backend
```

Do not force every backend to adopt semantics that only one vendor supports.

Provider contracts should make important behavior explicit:

- sync vs async work;
- cancellation;
- deadlines;
- transaction or atomicity guarantees;
- failure policy;
- lifecycle and shutdown;
- thread or event-loop confinement;
- ownership and Sendable requirements.

## Dependency policy

Follow the repository Tier 1 / fundamental dependency policy.

Before adding a package or system dependency:

- prove the capability cannot reasonably use Swift, SwiftNIO, an existing
  dependency, or a fundamental system interface;
- inspect transitive dependencies;
- record ownership and maintenance status;
- understand concurrency and allocation behavior;
- pin versions according to repository policy;
- verify the dependency does not drag another web/application framework into
  WhiteThroated;
- measure hot-path cost if the dependency participates in serving.

Do not add a large package just to avoid writing a small adapter.

Do not reimplement a mature cryptographic, TLS, database wire, or compression
stack from scratch without a separate correctness and performance case.

## Concurrency and I/O

Optional modules must preserve the core concurrency model.

Rules:

- never block a SwiftNIO event-loop thread;
- do not hide blocking I/O inside an apparently lightweight middleware API;
- use explicit executors or dedicated queues for blocking system libraries;
- keep event-loop-native work event-loop-native;
- do not create a Swift Task per request unless the chosen API semantics
  actually require structured concurrency;
- keep mutable connection state event-loop confined when possible;
- bound queues, caches, and per-client state.

A module that performs background work needs an explicit lifecycle and shutdown
story.

## Security defaults

Optional modules must not weaken secure defaults.

Examples:

- CORS should not silently become allow-all;
- proxy headers remain untrusted unless explicitly configured;
- session cookies should retain secure attributes appropriate to the deployment;
- rate limiting must not trust spoofable client identity by default;
- TLS must not gain trust-all defaults;
- static files must not permit path traversal or root escape;
- observability must not emit credentials or sensitive bodies by default.

Use the relevant security skill in addition to this one when a feature crosses a
security boundary.

## Observability discipline

An optional capability may emit logs, metrics, or traces, but it must not make
an exporter dependency mandatory for the module.

Prefer small event or sink contracts.

Do not use unbounded-cardinality values such as raw user IDs, arbitrary query
strings, credentials, or request bodies as default metric labels.

Instrumentation must not materially alter hot paths when no sink is installed.

## Public API rules

Optional modules should feel like native WhiteThroated capabilities.

Prefer:

- explicit installation;
- immutable configuration values;
- small public surfaces;
- clear error semantics;
- setup-time validation;
- APIs that reveal meaningful I/O or concurrency differences.

Avoid convenience APIs that hide:

- network calls;
- database work;
- Tasks;
- locks;
- global state;
- large buffer copies;
- per-request reflection.

Use `.agents/skills/api-ergonomics/SKILL.md` for user-facing API design.

## Testing matrix

For an optional module, test the applicable layers:

- setup validation;
- activation;
- ordinary success behavior;
- failure behavior;
- disabled or absent behavior;
- interaction with core routing;
- interaction with streaming when applicable;
- shutdown/lifecycle;
- concurrency or cancellation;
- malformed/adversarial input when the module parses external data.

Add at least one regression test proving that unrelated core behavior is not
silently changed when the module is unused or not applicable.

For cross-module integrations, test the contract boundary rather than relying
only on same-module unit tests.

## Benchmark gate

Use `.agents/skills/benchmark-validation/SKILL.md` whenever the module changes
the request path, connection path, allocation profile, memory use, or response
serialization.

At minimum distinguish:

- capability absent;
- capability installed but inactive for the tested request;
- capability active.

Do not publish a module as "zero overhead" without measurement.

If the module introduces a hook into core/runtime, measure the disabled hook path
against the previous core baseline.

## Documentation

Document:

- whether the module is experimental or stable;
- how it is installed and activated;
- dependencies and system requirements;
- concurrency and blocking behavior;
- lifecycle/shutdown behavior;
- security defaults;
- important memory or buffering limits;
- unsupported behavior;
- benchmark status when performance claims are made.

Do not let documentation imply automatic activation when the implementation is
opt-in.

## Review checklist

Before approving an optional-module change, verify:

- dependency direction remains one-way toward core;
- no framework concepts leaked into runtime;
- unused applications pay no hidden initialization;
- unrelated routes do not pay new request-time work without evidence;
- blocking I/O stays off event loops;
- provider contracts do not encode one backend's quirks as universal semantics;
- lifecycle and shutdown are explicit;
- security defaults remain conservative;
- tests cover inactive and active states;
- benchmarks exist when the hot path changed;
- documentation matches actual activation semantics.

## Stop conditions

Reject or redesign the change when:

- core/runtime now depends on an optional module;
- an import automatically changes serving behavior;
- an unused feature allocates or branches materially on every request;
- application-specific state is pushed into runtime;
- blocking I/O is hidden on an event loop;
- a backend dependency dictates the generic capability contract;
- the feature requires weakening security or correctness invariants;
- benchmark gains come from changing response semantics;
- the module becomes a grab bag of unrelated responsibilities.
