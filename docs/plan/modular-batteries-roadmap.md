# WhiteThroated Optional Modules Plan

Status: implemented (experimental)

Phases 0–6 are implemented in the modular monorepo. This status closes the
implementation roadmap; it does **not** promote any module from experimental to
preview/stable, and it does not claim that WhiteThroated's broader external
performance goals are complete. Module promotion still follows the release
gates in section 10.

This document plans application facilities on top of `WhiteThroated` without
putting them into the core hot path. The product names and example APIs below
are still a design; behavior and contracts must be locked down through API
proposals, tests, and benchmarks before an implementation is considered
stable.

## 1. Goals

- Provide a "batteries available" experience without making every feature a
  mandatory cost.
- Keep `WhiteThroated` as a small, fast HTTP core that can be used on its own.
- Make every capability independently installable through SwiftPM.
- Keep the Swift API explicit about I/O, concurrency, storage, and
  request-time cost.
- Provide official integrations with third-party implementations without
  forcing one database, exporter, or deployment platform.

## 2. Non-goals

- Moving the ORM, authentication, templates, telemetry, or deployment
  orchestration into `WhiteThroatedRuntime`.
- Unifying prepared, synchronous, future, and async handlers into one
  abstraction that makes the cheap path pay for a `Task` or an
  `EventLoopFuture`.
- Rewriting mature database drivers, TLS stacks, compressors, or telemetry
  backends without a measurable correctness and performance reason.
- Implicitly enabling logging, metrics, tracing, compression, sessions, or
  rate limiting.
- Promising stable API compatibility while WhiteThroated is still pre-alpha.

## 3. Architecture principles

### 3.1 The core stays independent

The dependency graph must be one-way:

```text
Optional application modules
        |
        v
WhiteThroated
        |
        v
WhiteThroatedRuntime -> WhiteThroatedHTTP1 -> SwiftNIO
```

`WhiteThroated`, `WhiteThroatedRuntime`, and `WhiteThroatedHTTP1` must not
depend on optional modules. Optional modules must not add framework concepts
to the runtime, such as user identity, sessions, schemas, ORM models, spans,
or a static-file root.

Exceptions are only for core hooks that are genuinely required by several
modules. Such a hook must:

- be a concrete value/closure, not a global service locator;
- be built at setup time and immutable while serving;
- have a `nil`/disabled path that does not allocate per request;
- not change the semantics of prepared, sync, future, and async responders;
- ship with before/after benchmarks if it touches the hot path.

### 3.2 Small products, an optional umbrella

Every capability is published as a separate library product. An umbrella
product may be provided purely as an import convenience and must not
activate features automatically.

Example package shape:

```swift
.library(name: "WhiteThroatedAuth", targets: ["WhiteThroatedAuth"])
.library(name: "WhiteThroatedSessions", targets: ["WhiteThroatedSessions"])
.library(name: "WhiteThroatedStaticFiles", targets: ["WhiteThroatedStaticFiles"])
.library(name: "WhiteThroatedObservability", targets: ["WhiteThroatedObservability"])
```

The initial decision is a **modular monorepo**: all official contracts and
modules that are still incubating live in the WhiteThroated repository, but
each is a separate SwiftPM target and library product. A core-only
application must not pull in, initialize, or execute modules it did not
choose.

Splitting repositories is not a requirement for binary or dependency
modularity. A new module is moved into its own package/repository after its
integration API is stable, its ownership and release cadence are clear, and
cross-package CI is available.

Use this hybrid structure in the long term:

```text
Main WhiteThroated repository
  - core and runtime
  - capability contracts
  - lightweight official modules
  - cross-module integration tests

Separate official adapter repositories
  - database/vendor drivers
  - Redis session/rate-limit stores
  - JWT/OIDC providers
  - OpenTelemetry exporters
  - additional compression backends

Community repositories
  - vendor- or platform-specific integrations
```

Criteria for moving an adapter/module into its own repository:

- it carries a large or specialized external dependency;
- it has a different release cadence or maintainer;
- changes to the module rarely require core changes;
- its contract API is stable and has a compatibility matrix;
- its CI, platform, or operational lifecycle differs materially;
- it can be useful to more than one framework.

### 3.3 Setup-time first and opt-in

- Configuration is compiled/finalized before `run` or `listen`.
- Routes and middleware that do not use a module do not pay for module
  lookups.
- Request parsing stays lazy if the value is not yet needed.
- Immutable policies, schemas, template metadata, and headers are prepared
  at setup.
- Blocking I/O must be moved off the event loop onto an explicit executor.
- Mutable request/connection state stays event-loop confined where possible.

### 3.4 Providers and adapters

A module that needs a backend defines a small contract and official adapters:

```text
WhiteThroated API -> capability contract -> adapter -> backend
```

Example: the session API does not know Redis directly. It uses a
`SessionStore`; the Redis adapter lives in another product. The contract
must not force every backend into a concurrency or transaction model that
does not suit it.

### 3.5 Safe defaults

- Session cookies default to `HttpOnly`, `Secure` over HTTPS, and a
  documented `SameSite`.
- Secrets, tokens, cookies, authorization headers, and sensitive bodies are
  not logged by default.
- Static files reject path traversal and symlink escapes per policy.
- CORS defaults to deny for cross-origin requests that are not configured.
- CSRF is active only on the browser/cookie authentication model it suits.
- Proxy headers are not trusted without an explicit `TrustedProxy`.
- TLS has no trust-all mode or validation-off mode as a default.

### 3.6 Tier 1 / fundamental dependencies

New dependencies must come from Tier 1 or be fundamental. This rule applies
to direct and transitive dependencies alike.

Considered Tier 1 / fundamental:

- the Swift standard library and Foundation;
- SwiftNIO and official SwiftNIO modules;
- official Swift project packages that are low-level and not owned by
  another web framework, such as Swift Crypto, Swift Log, Swift Metrics,
  Swift Collections, Swift Atomics, Swift System, and Swift Service
  Lifecycle;
- system libraries / fundamental OS interfaces such as SQLite, libpq,
  POSIX, or OpenSSL, accessed through a system-library target and without
  adding non-Swift implementation source to the repository.

Forbidden:

- packages owned by another framework/ecosystem, including all `vapor/*`
  packages;
- packages that transitively pull in another web or application framework;
- wrapping another framework's driver as an official dependency adapter;
- choosing a framework package only because its API is convenient when an
  adequate Tier 1/fundamental path exists.

If a capability needs a backend that has no Tier 1/fundamental driver, the
permitted choices are:

1. build a thin Swift adapter on top of a system library/fundamental
   interface;
2. defer the capability; or
3. request an explicit dependency exception with a separate review.

Rewriting a database protocol, TLS stack, or codec from scratch is still
not the default. An exception must not be disguised as a "thin adapter".

Every new dependency must record:

- its functional rationale and why Tier 1/fundamental is not sufficient;
- its license and ownership;
- its transitive dependency graph;
- its allocation, concurrency, and lifecycle costs;
- an exact pin in `Package.resolved`;
- its benchmark impact if it touches the hot path.

## 4. Module catalog

### 4.1 Authentication, sessions, validation

This category is split so that stateless API tokens do not need to pull in a
session store, CSRF, OpenAPI, or a rate limiter.

#### `WhiteThroatedAuth`

Responsibilities:

- the `Authenticator`, `Principal`, `Credential`, and `AuthorizationPolicy`
  contracts;
- authentication middleware for bearer tokens, API keys, and session
  principals;
- route/group authorization based on policy, role, or permission;
- consistent `401` and `403` responses;
- opt-in hooks for auditing without recording credentials.

Limits:

- password hashing becomes a dedicated adapter using a maintained
  cryptography library; do not invent your own cryptographic algorithm;
- JWT/OAuth/OIDC become separate adapters so their dependencies and network
  behavior are not paid for by simple-auth users;
- authentication must not automatically imply authorization.

Candidate API:

```swift
app.use(authentication: authenticator)
app.group("/admin").authorize(AdminPolicy())
```

#### `WhiteThroatedSessions`

Responsibilities:

- session ID lifecycle: create, load, rotate, expire, destroy;
- signed/encrypted cookie metadata;
- the `SessionStore` contract with an in-memory adapter for
  development/tests;
- Redis/database adapters as separate products;
- TTL, idle expiration, fixation protection, and key rotation.

Key invariants:

- an asynchronous store must not block the event loop;
- a request that never accesses a session should not perform a
  decode/store lookup if a lazy mode can be preserved;
- session IDs must be rotated after a privilege change/login;
- the memory store is not a recommendation for multi-process production.

#### `WhiteThroatedCSRF`

Responsibilities:

- synchronizer tokens or a signed double-submit cookie;
- integration with session/cookie authentication;
- documented exceptions for safe methods and an origin/referrer policy;
- a customizable failure response.

Required tests cover a missing token, a wrong token, replay per policy,
safe methods, cross-origin cases, cookie attributes, and trusted
proxy/HTTPS interaction.

#### `WhiteThroatedRateLimit`

Responsibilities:

- fixed window, sliding window, and/or token bucket;
- an explicit key resolver: trusted IP, principal, API key, or an
  application closure;
- a local in-memory limiter and a distributed-store contract;
- `Retry-After` and documented limit headers;
- bounded state and eviction.

The limiter must not trust `X-Forwarded-For` without a `TrustedProxy`
configuration. Atomicity and the failure policy for a distributed store
must be explicit: fail-open or fail-closed, never hidden.

#### `WhiteThroatedValidation`

Responsibilities:

- request schemas for path, query, header, cookie, and body;
- structured validation errors with field locations;
- `Codable` integration without forcing a decode when the handler does not
  need the body;
- size and depth limits for data.

#### `WhiteThroatedOpenAPI`

Responsibilities:

- generate OpenAPI from route/schema metadata;
- serve the JSON/YAML document and UI only when enabled;
- keep documentation schemas and validation driven by the same contract
  source;
- detect operation ID and route collisions at setup.

OpenAPI depends on `WhiteThroatedValidation`, not the other way around.
Ordinary routes must remain registerable without OpenAPI metadata.

### 4.2 Database and business services

#### `WhiteThroatedServices`

Provides a dependency registry with clear scopes:

- application singletons for immutable pools/configuration;
- connection/request scope only when genuinely needed;
- factories and shutdown hooks;
- easy overrides for tests.

The registry must not perform runtime reflection or a global lookup on
every request. The initial preference is a typed application context or a
generated key, not a dictionary of `Any` accessed repeatedly on the hot
path.

#### `WhiteThroatedDatabase`

Responsibilities:

- contracts for connection pool, lease, transaction, query cancellation,
  and shutdown;
- request deadline/cancellation integration where the backend supports it;
- official adapters for a database chosen later;
- observability hooks without a mandatory exporter dependency.

Database work must be non-blocking or run on a dedicated executor. Pools
must not be created per request.

Official database adapters must follow the Tier 1/fundamental dependency
rule in section 3.6. Driver packages owned by another framework, such as
`vapor/*`, must not be used. If no Tier 1/fundamental driver is available,
the adapter must be built on top of a system library/fundamental interface
or the capability is deferred until there is a separate dependency
decision.

#### `WhiteThroatedPostgres` (Phase 4 proof adapter)

The initial production adapter for PostgreSQL is built directly on top of
the system library `libpq` through a SwiftPM target `CPostgres`:

- a system library and header declarations, not a non-Swift protocol
  implementation;
- an actor pool with leases, lazy connection creation, replacement of
  broken connections, and draining on shutdown;
- one serial `DispatchQueue` per physical connection so blocking libpq
  calls never run on an event loop;
- cancellation through `PQcancel`, transaction rollback, SQLSTATE mapping,
  and mapping of PostgreSQL types to `DatabaseValue`;
- a session-level advisory lock for the migration runner.

The adapter adds no dependency on another framework's module. `numeric`,
date/time, JSON, array, and extension types are preserved as text so
precision is not silently lost.

#### `WhiteThroatedORM`

Initial-stage responsibilities:

- typed query/model mapping on top of the database adapter;
- explicit fetch/insert/update/delete;
- visible transaction boundaries;
- unsurprising eager/lazy relationship behavior.

The ORM must start only after the database contract is stable. Avoid
active-record magic, implicit N+1 queries, hidden global connections, or
queries triggered by property reads.

#### `WhiteThroatedMigrations`

Responsibilities:

- migration IDs and checksums;
- ordered apply, status, dry-run, and explicit rollback where available;
- locking so two instances do not migrate at the same time;
- a CLI executable separate from the server request path.

Migrations are not run automatically as the server starts receiving
traffic unless the application explicitly chooses that mode.

### 4.3 HTML rendering / static assets

The scope of this category for the initial roadmap is a static-file server,
not a template engine. Technically static files are asset serving, not HTML
rendering; the category name is kept to match the requested product
grouping.

#### `WhiteThroatedStaticFiles`

Responsibilities:

- mount one or more directories at a URL prefix;
- MIME types, optional index files, cache policy, and download disposition;
- `GET`/`HEAD`, conditional requests, single ranges, and `FileRegion`;
- precompressed `.br`/`.gz` only after correct `Accept-Encoding`
  negotiation;
- an explicit SPA fallback that does not accidentally swallow API routes.

Security and correctness:

- percent-decoding normalization must happen exactly once under a clear
  policy;
- reject `..`, disguised separators, NUL, absolute paths, and root escapes;
- the symlink policy must be configurable and safe by default;
- no directory listing by default;
- file stat/open races and changes during transfer must be handled;
- the fast header path must still go through response-header validation.

Candidate API:

```swift
app.mountStatic(
    "/assets",
    directory: assetsURL,
    options: .production
)
```

### 4.4 Observability

#### `WhiteThroatedObservability`

An umbrella integration for three independent capabilities:

- structured logging;
- metrics;
- tracing.

Subtargets or adapter products may include:

- `WhiteThroatedLogging` for `swift-log` or a chosen internal sink;
- `WhiteThroatedMetrics` for counters, gauges, and histograms;
- `WhiteThroatedTracing` for W3C Trace Context/OpenTelemetry adapters.

Standard request data:

- request/correlation ID;
- method and route template, not the raw URI as a metrics label;
- status class, duration, response bytes, and error category;
- connection/stream counters with bounded cardinality.

Important rules:

- disabled instrumentation must have a direct path with no span/event;
- metrics must not use user IDs, raw paths, queries, or request IDs as
  labels;
- tracing sampling must be decided before building expensive attributes;
- logging of sensitive bodies/headers is opt-in with redaction;
- network exporters must not block the event loop;
- health/readiness is not a substitute for metrics and tracing.

### 4.5 Production deployment

#### `WhiteThroatedTLS`

Responsibilities:

- HTTPS configuration through a maintained TLS adapter;
- certificate chain, private key, ALPN policy, and minimum TLS version;
- a reload/rotation strategy where the backend allows it;
- explicit direct TLS versus TLS termination at a reverse proxy.

The core can still run plain HTTP behind a trusted reverse proxy. Scheme
and secure-cookie decisions may only use forwarded headers through an
explicit `TrustedProxy`.

#### `WhiteThroatedCompression`

Responsibilities:

- correct `Accept-Encoding` negotiation;
- gzip first; Brotli/Zstandard only through a separately evaluated
  dependency/adapter;
- thresholds, a content-type allowlist, and skips for small or
  already-compressed bodies;
- streaming compression with backpressure;
- correct `Vary: Accept-Encoding`, ETag/range/cache semantics;
- a ban on compressing sensitive responses where side-channel mitigation
  policy requires it.

Prepared responses may have precompressed variants prepared at setup.
Routes without compression must not pay for compressor allocation.

#### `WhiteThroatedLifecycle`

Runtime-operational responsibilities:

- graceful shutdown and drain timeouts;
- readiness changes before the listener is stopped;
- ordered cleanup of services/databases/exporters;
- signal handling that can be disabled for embedding/tests.

#### Deployment tooling

This is not a request-path library. Its deliverables include:

- release build and container image examples;
- an environment/secrets configuration guide;
- health/readiness endpoint recipes;
- a graceful shutdown recipe;
- reverse-proxy and direct-TLS examples;
- CI/CD and Kubernetes/systemd templates once validated;
- migration, rollout, rollback, and observability checklists.

Deployment templates must be labeled as examples, not as safety guarantees
for every infrastructure. Do not add non-Swift source for WhiteThroated
benchmarks or runtime; deployment metadata files must still comply with
repository policy.

### 4.6 Additional communication/protocols

#### `WhiteThroatedCORS`

Responsibilities:

- simple requests and preflight;
- exact origins, a bounded allowlist, and a dynamic origin resolver;
- method/header/exposed-header policy;
- credentials and max-age;
- `Vary: Origin`/preflight cache semantics.

A wildcard origin must not be combined with credentials in an invalid way.
Rejection/pass-through behavior must be explicit and tested for route
misses and middleware ordering.

#### `WhiteThroatedWebSocket`

Responsibilities:

- the upgrade handshake and subprotocol negotiation;
- a frame/message API, fragmentation, ping/pong, and the close handshake;
- message and frame size limits;
- backpressure, cancellation, disconnects, and exactly-once cleanup;
- optional compression as a separate capability.

The first implementation should use SwiftNIO WebSocket primitives through
the stock NIO pipeline. Do not extend the Tier 1 parser before the stock
path's semantics, differential tests, lifecycle, and benchmarks are mature.
An application that registers WebSocket may choose the pipeline at setup
time; non-WebSocket routes must not perform upgrade bookkeeping when the
capability is absent.

## 5. Proposed dependency graph

```text
WhiteThroated
  +-- StaticFiles
  +-- CORS
  +-- Validation <-- OpenAPI
  +-- Auth <-- Sessions <-- CSRF
  |      \------ Authorization policies
  +-- RateLimit <-- optional distributed-store adapter
  +-- Services
  +-- Database <-- ORM
  |            <-- Migrations CLI
  |            \-- Postgres adapter (system libpq)
  +-- Observability
  |      +-- Logging adapter
  |      +-- Metrics adapter
  |      \-- Tracing adapter
  +-- TLS
  +-- Compression
  +-- Lifecycle
  \-- WebSocket
```

Inter-module dependencies should be as few as possible. In particular:

- every external dependency must follow the Tier 1/fundamental rule in
  section 3.6;
- Auth does not mandatorily depend on Sessions.
- Validation does not depend on OpenAPI.
- Observability is not a mandatory dependency of other modules; other
  modules only emit events through small optional hooks.
- StaticFiles does not depend on Compression; the two integrate through a
  capability or precompressed-asset configuration.
- WebSocket does not depend on Auth, but an upgrade route can use the same
  auth middleware.

## 6. Implementation order

### Implementation status

| Phase | Status | Primary evidence |
| --- | --- | --- |
| 0 — Contracts and package skeleton | Implemented | Separate SwiftPM products/targets, one-way core/runtime dependency direction, release CI, shared test support, and documented architecture/benchmark baselines. |
| 1 — Independent HTTP modules | Implemented, experimental | `WhiteThroatedCORS`, `WhiteThroatedStaticFiles`, `WhiteThroatedValidation`, and `WhiteThroatedRateLimit` with module tests and documentation. |
| 2 — Observability and lifecycle | Implemented, experimental | Logging, metrics, tracing, and lifecycle products plus application-level composition coverage in `WhiteThroatedObservabilityTests`. |
| 3 — Identity and state | Implemented, experimental | Auth, authorization, sessions, Redis session adapter, CSRF, and auth-aware rate limiting covered by `WhiteThroatedIdentityStateTests`. |
| 4 — Data and services | Implemented, experimental | Services, database contract, system-libpq PostgreSQL adapter, migrations CLI, minimum ORM, and database/services composition coverage. |
| 5 — Production HTTP | Implemented, experimental | Buffered/streaming compression, direct TLS, and the lifecycle-aware `whitethroated-deployment-example` validated by Linux CI; see `docs/deployment.md`. |
| 6 — WebSocket and OpenAPI | Implemented, experimental | Stock-pipeline WebSocket lifecycle/auth/telemetry coverage, shared Validation/OpenAPI contracts, deterministic WebSocket corpus tests, and registration-order differential OpenAPI tests. |

### Phase 0 — Contracts and package skeleton

Deliverables:

- record the core test/build/benchmark baseline;
- create separate target/product skeletons in the monorepo per the
  architecture decision;
- establish naming, a semantic version policy, and dependency direction;
- create an integration test fixture usable by all modules;
- define the setup-time configuration and lifecycle shutdown rules;
- audit whether a new core hook is genuinely needed.

Exit gate:

- the dependency graph has no cycles;
- a module-free application produces the same behavior and dispatch path;
- the core baseline is documented before any hook is added.

### Phase 1 — The most independent HTTP modules

Implement in order:

1. `WhiteThroatedCORS`;
2. `WhiteThroatedStaticFiles`;
3. `WhiteThroatedValidation`;
4. `WhiteThroatedRateLimit` with a bounded in-memory store.

Rationale: these modules exercise the extension surface, middleware
ordering, filesystem I/O, lazy request access, and provider contracts
without first locking in a broader identity or database design.

### Phase 2 — Observability and lifecycle

Implement:

1. request IDs and structured logging;
2. bounded-cardinality HTTP metrics;
3. trace-context propagation and tracing;
4. graceful shutdown/readiness through `WhiteThroatedLifecycle`.

Observability is built after the extension surface is proven, but before
auth and the database, so the following modules can be operated and
measured from the start.

### Phase 3 — Identity and state

Implement:

1. auth principal + authentication middleware;
2. authorization policy;
3. an in-memory session store for tests/development;
4. one production session adapter;
5. CSRF;
6. auth-related rate-limit integration.

A security review is mandatory before marking the API production-ready.

### Phase 4 — Data and services

Implement:

1. typed service registry/lifecycle;
2. database pool/transaction contract;
3. one database adapter as a proof of design;
4. migrations CLI;
5. a minimum ORM after query and transaction semantics are stable.

Do not design the ORM first and then force the database contract to follow
the ORM.

Phase 4 remains experimental: the database
contract, the system-libpq adapter, the migrations CLI, and the minimum
ORM are available with unit and integration test coverage. Migrations are
still forward-only; the ORM has no relationships or lazy loading yet.
Evidence and operational limits are recorded in `docs/data-services.md`.

### Phase 5 — Production HTTP

Implement:

1. compression for buffered responses;
2. compression for streaming with backpressure;
3. direct TLS configuration;
4. validated deployment examples and an operational checklist.

### Phase 6 — WebSocket and OpenAPI completion

Implement:

1. WebSocket stock-pipeline handshake and lifecycle;
2. auth/observability integration for upgrade connections;
3. OpenAPI document generation;
4. a shared validation/OpenAPI schema source;
5. hardening, fuzz/differential tests, and a cross-module API review.

This phase does not mean the two features depend on each other; they are
placed last because they need a more mature route/schema or transport
contract.

## 7. Design checklist for every module

Every module proposal must answer:

1. What are its public semantics and error model?
2. What happens when the module is not installed, and when it is installed
   but a route does not use it?
3. What work happens at setup, per connection, and per request?
4. Is there any new allocation, copy, ARC traffic, lock, `Task`, future, or
   event-loop hop?
5. How do cancellation, shutdown, and resource cleanup work?
6. What data is sensitive, and how do redaction/secure defaults work?
7. Are input/output still RFC-correct for `HEAD`, bodyless statuses,
   keep-alive, ranges, conditional requests, and streaming?
8. Is state bounded, and what are the eviction/backpressure strategies?
9. Which backends/providers are mandatory and which are optional?
10. How is the API tested without a network, and when is a real network
    test needed?
11. Which benchmark proves the feature cost and disabled-path neutrality?
12. What documentation, migration guide, and minimal example are needed?

## 8. Testing strategy

Every module target has its own unit tests and integration tests. Minimum:

- happy path, miss/pass-through, invalid input, boundaries, and cleanup;
- middleware ordering and short-circuiting;
- prepared, sync, future, and async route compatibility where relevant;
- stock and Tier 1 transport equivalence, unless the capability explicitly
  chooses stock;
- keep-alive, pipelining, body limits, streaming, disconnects, and write
  failures for transport features;
- deterministic clock/random/store injection for sessions, rate limits,
  and auth;
- adversarial path/header/framing tests for static files, CORS, CSRF, TLS,
  and compression;
- compile-time API usage tests for overloads and type inference;
- a full `swift test -c release` before a milestone is complete.

Security-sensitive parsers/policies get fuzz or property tests where the
chosen Swift tooling can be reproduced in CI.

## 9. Benchmark strategy

Every hot-path feature has three conditions:

1. module not installed/disabled;
2. module installed but the route does not use it;
3. module active on the route.

Primary acceptance:

- condition 1 stays equal to the core baseline;
- condition 2 is neutral within noise, or its overhead is measured and
  approved;
- condition 3 is compared against a control with identical semantics;
- no "faster" claim based on a debug build or a single run;
- p50/p90/p99/p99.999/max, errors, RPS, and completed requests are
  recorded;
- peak RSS is mandatory for sessions, rate limits, static files,
  compression, WebSocket, the database pool, and exporter buffering;
- response throughput is mandatory for static files, compression, and
  WebSocket;
- benchmarks use release mode, warm-up, multiple rounds, and alternating
  A/B order per `BENCHMARKS.md`.

Add an opt-in feature-specific matrix so benchmark routes do not
contaminate the baseline server.

## 10. Versioning and release gates

Maturity stages per module:

```text
experimental -> preview -> stable
```

- **Experimental:** the API may change; basic correctness coverage exists.
- **Preview:** API review complete, docs complete, a real integration
  adapter, a security review, and a benchmark record are available.
- **Stable:** a compatibility policy, a migration guide, a CI platform
  matrix, a production incident policy, and a clear maintenance owner.

A module must not be promoted merely because its feature can be demoed.
The preview/stable gates include:

- release tests and the relevant products build;
- public API documentation and a minimal example;
- failure/cancellation/shutdown semantics;
- a security checklist;
- disabled-path and enabled-path benchmark evidence;
- a dependency/license review;
- no silent changes to core semantics.

## 11. Documentation to produce

For every module:

- a short README with installation and a minimal example;
- an API reference and concurrency/blocking notes;
- security defaults and threat boundaries;
- an operational guide and observability fields;
- a backend adapter matrix;
- benchmark methodology/results that separate facts from hypotheses;
- migration notes for breaking changes.

The WhiteThroated root documentation must distinguish:

- features that are in the core;
- official modules that are stable;
- preview/experimental modules;
- community/third-party integrations.

## 12. Decisions to make before implementation

1. Minimum platform versions beyond macOS, and the Linux CI targets for new
   modules.
2. External dependencies allowed for crypto, TLS, compression,
   observability, and databases. Decision: Tier 1/fundamental only, per
   section 3.6; framework/ecosystem packages such as `vapor/*` are
   forbidden. The Phase 4 proof adapter uses the system `libpq`, not
   another framework's driver package.
3. The shape of the core extension surface: middleware only, typed
   application storage, lifecycle hooks, or a minimal combination.
4. The environment/secrets configuration model and shutdown ownership.
5. The first module to use as a vertical slice. Recommendation: CORS for a
   middleware-only slice, then StaticFiles for I/O and HTTP correctness.
6. Compatibility standards and release cadence between packages.

## 13. Token estimate to production-ready

This estimate uses **total model tokens**: input, output, repository
context, tool/test/benchmark results, reviews, and fix iterations. The
figures are not a measure of source code and are not a guarantee of cost,
duration, or quality. Tokens are a rough planning tool; the release gate is
still determined by correctness, security, interoperability, and benchmark
evidence.

Scope assumptions:

- implementation proceeds in stages by a coding agent with human review;
- macOS and Linux are the primary platforms;
- one production database adapter and one session/distributed-store
  adapter;
- gzip is the compression baseline;
- WebSocket starts from the stock SwiftNIO pipeline;
- crypto, TLS, database protocols, and exporters are not rewritten from
  scratch;
- the API may undergo rework during the experimental/preview stages;
- the estimate includes tests, documentation, benchmarks, and hardening;
- the estimate excludes many vendor adapters or broad cloud-platform
  support.

### Budget per phase

| Phase | Main scope | Token estimate |
| --- | --- | ---: |
| 0 | Contracts, package skeleton, baseline, extension surface | 0.5–0.9 million |
| 1 | CORS, StaticFiles, Validation, RateLimit | 1.75–3.15 million |
| 2 | Logging, metrics, tracing, lifecycle/shutdown | 1.3–2.35 million |
| 3 | Authentication, authorization, sessions, CSRF, store adapter | 2.5–4.55 million |
| 4 | Services, database contract/adapter, migrations, ORM | 3.7–6.65 million |
| 5 | Compression, TLS, deployment tooling | 1.65–2.95 million |
| 6 | WebSocket, OpenAPI, integration hardening | 2.8–5.0 million |
| Cross-phase | Final audit, docs reconciliation, release fixes | 0.8–1.6 million |
| **Engineering subtotal** |  | **15.0–27.15 million** |
| **Rework reserve 20–30%** | API churn, bugs, benchmark regressions | **3.0–8.15 million** |
| **Working budget** | Until the whole scope deserves to be called production-ready | **18–35 million** |

Use **20–35 million tokens** as a realistic program budget. A target around
18 million only makes sense if the contracts stabilize quickly, the chosen
dependencies fit, and test/benchmark results do not require a major
redesign. The upper bound can be exceeded if the ORM is made very broad,
Tier 1 is extended for WebSocket, or many official backends are brought
into the initial scope.

### Budget by product milestone

There is no need to wait for the entire catalog to finish to produce a
useful release:

| Milestone | Contents | Estimated cumulative tokens |
| --- | --- | ---: |
| Modular foundation | Phase 0 | 0.5–0.9 million |
| HTTP batteries preview | Phases 0–1 | 2.25–4.05 million |
| Operable HTTP release | Phases 0–2 | 3.55–6.4 million |
| Secure application preview | Phases 0–3 | 6.05–10.95 million |
| Data-backed application preview | Phases 0–4 | 9.75–17.6 million |
| Production HTTP candidate | Phases 0–5 | 11.4–20.55 million |
| Full roadmap candidate | Phases 0–6 + final audit/rework | 18–35 million |

A milestone does not automatically mean production-ready. Every milestone
must still pass the release gates of the modules it includes.

### Factors that consume the most tokens

- lifecycle and concurrency bug reviews that only surface on disconnects,
  cancellation, pipelining, or shutdown;
- adversarial security tests for auth, sessions, CSRF, path traversal,
  CORS, compression, and proxy boundaries;
- ORM semantics, transaction behavior, migration locking, and backend
  interoperability;
- repeated before/after benchmarks and regression diagnosis on the hot
  path;
- WebSocket framing, backpressure, the close handshake, and integration
  with auth;
- documentation/API reconciliation after contracts change.

### Additional costs beyond the baseline

Use the following ranges for scope changes:

- an additional production database adapter: 0.5–1.2 million tokens per
  adapter;
- an additional session/rate-limit store: 0.25–0.65 million per adapter;
- a complete JWT or OIDC provider: 0.5–1.2 million per provider;
- an additional telemetry exporter: 0.25–0.6 million per exporter;
- an additional compression codec: 0.2–0.5 million per codec;
- a validated deployment platform: 0.25–0.75 million per platform;
- WebSocket support on a custom Tier 1 transport: an additional
  1.0–2.5 million;
- a full template engine, if brought back into scope: 1.0–2.5 million.

### Controlling token usage

- Work one vertical slice to its release gate before opening many modules.
- Use a short API proposal before implementation to reduce rework.
- Keep per-module context; do not load the entire repository on every
  iteration.
- Run targeted tests during iteration and the full release suite at
  milestones.
- Use benchmarks only once correctness is stable.
- Record architecture decisions so the next agent does not repeat the
  investigation.
- Stop expanding scope if a second adapter has not yet proven a weakness
  in the first contract.

Budgets should be allocated per milestone, not granted all at once. After
each phase, compare actual tokens, the amount of rework, test failures,
and benchmark regressions to update the estimate for the next phase.

## 14. Definition of done for the modular roadmap

The roadmap counts as realized when:

- every capability can be selected without an umbrella dependency;
- a core-only application does not pay for feature bookkeeping it does not
  use;
- the dependency graph stays one-way and the runtime stays free of
  application concepts;
- every module has correctness, security, lifecycle, and benchmark gates;
- cross-module integration across auth/session/CSRF, validation/OpenAPI,
  static/compression, database/services, and observability is proven;
- deployment examples have been tested in the documented environment;
- the README does not call WhiteThroated "batteries included" without
  explaining the modules, their maturity status, and the features that are
  actually available.

### Closure evidence

| Gate | Evidence |
| --- | --- |
| Independent capability selection | `Package.swift` publishes each official capability as a separate library product. There is no umbrella product that activates modules automatically. |
| Core/runtime isolation | Optional products depend toward `WhiteThroated`; `WhiteThroated` depends on `WhiteThroatedRuntime`, which depends on `WhiteThroatedHTTP1`/SwiftNIO. Runtime targets do not depend on optional application modules. |
| Correctness and release gates | Module-specific Swift test targets run under the full `swift test -c release` CI gate. Section 9 defines the common benchmark gate; section 10 keeps benchmark records mandatory for preview/stable promotion rather than inventing CI timing claims. |
| Auth/session/CSRF composition | `Tests/WhiteThroatedIdentityStateTests/IdentityStateTests.swift` covers authentication, authorization, sessions, CSRF, and auth-aware rate limiting. |
| Validation/OpenAPI composition | `Tests/WhiteThroatedOpenAPITests/OpenAPITests.swift` consumes the same `ValidationSchema` contract used at runtime and includes deterministic registration-order differential coverage. |
| Static/compression composition | `Tests/WhiteThroatedStaticFilesTests/StaticFilesCompressionIntegrationTests.swift` proves full and range static responses preserve their representation semantics with compression middleware installed. |
| Database/services composition | `Tests/WhiteThroatedDataServicesTests/DatabaseServicesIntegrationTests.swift` proves typed database resolution, query execution, result decoding, and shutdown ownership through the service registry. |
| Observability composition | `Tests/WhiteThroatedObservabilityTests/ObservabilityLifecycleTests.swift` installs lifecycle, logging, metrics, and tracing on one application and verifies one request crosses all observers without leaking active lifecycle state. |
| WebSocket hardening | `Tests/WhiteThroatedWebSocketTests/WebSocketTests.swift` covers handshake/auth, protocol violations, limits, close semantics, lifecycle telemetry, and a deterministic masked binary frame corpus. |
| Deployment validation | CircleCI builds and starts `whitethroated-deployment-example` on Linux, verifies readiness/health/application responses over a real TCP listener, sends `SIGTERM`, and requires clean process exit. The same contract is retained in the manual GitHub Actions parity workflow. See `docs/deployment.md`. |
| Maturity disclosure | The root README identifies WhiteThroated as pre-alpha and labels optional module phases experimental. No preview/stable promotion is implied by roadmap closure. |

Roadmap closure means the planned modular capability slices and their integration
evidence exist. It does not supersede module-specific preview/stable gates,
Linux performance campaigns, external framework comparisons, or the broader
goal of reducing the remaining gap to the fastest Rust frameworks.
