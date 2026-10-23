# Skill: data persistence

Use this skill whenever changing WhiteThroatedServices, WhiteThroatedDatabase,
WhiteThroatedPostgres, WhiteThroatedMigrations, WhiteThroatedORM, database test
support, or any future persistence adapter.

This skill covers connection ownership, pooling, transactions, cancellation,
query/value semantics, migrations, ORM behavior, and persistence lifecycle.

## Principle

Persistence correctness is primarily about ownership and state transitions.

A database abstraction is safe only when connections, transactions,
cancellation, and shutdown have unambiguous ownership across success, failure,
and task cancellation.

Do not optimize away state transitions that protect connection reuse.

## Layer boundaries

Preserve this dependency direction:

```text
WhiteThroatedServices        (independent)
WhiteThroatedDatabase        (driver-neutral contract)
        ^
        |
        +-- WhiteThroatedPostgres
        +-- WhiteThroatedMigrations
        +-- WhiteThroatedORM

Migration CLI -> Migrations + Postgres
```

The generic database contract must not depend on PostgreSQL-specific concepts
unless they are deliberately exposed as an optional escape hatch.

The ORM must not become the database contract.

Migrations must not require the ORM.

## Event-loop rule

Never block a SwiftNIO event-loop thread on persistence work.

If a backend library is synchronous, isolate it on a dedicated queue or executor
whose ownership and shutdown are explicit.

Do not disguise blocking work behind an `async` function while executing the
blocking call on the event loop or cooperative executor in an uncontrolled way.

For libpq-backed work, preserve the repository's dedicated per-connection
blocking execution model unless a separately validated design replaces it.

## Pool invariants

A connection pool must have explicit behavior for:

- minimum/maximum size;
- lazy or eager connection creation;
- lease acquisition;
- wait-queue ordering;
- cancellation while waiting;
- connection failure;
- replacement of broken connections;
- return after success;
- return after query error;
- return after transaction error;
- shutdown while leases exist.

A connection lease must be returned at most once.

A physical connection that is not reusable must never be returned to the idle
pool.

A cancelled waiter must be removed from the wait queue and must not later
receive a connection.

Do not create a new physical connection per HTTP request.

## Connection ownership

A connection borrowed for a closure or transaction belongs to that operation
until the operation has completed its cleanup.

Do not expose a leased connection outside the lifetime in which the pool can
prove ownership.

Avoid hidden concurrent use of one physical database connection unless the
backend explicitly supports pipelining/multiplexing and the adapter has a state
machine that proves correctness.

For session-dependent behavior, keep all relevant statements on the same
physical connection.

## Transaction invariants

Transactions must have a single terminal outcome.

For a transaction body:

```text
begin
  |
  +-- success ------> commit ------> reusable connection
  |
  +-- throw --------> rollback ----> reusable or discard
  |
  +-- cancellation -> rollback ----> reusable or discard
```

If rollback fails or the connection enters an uncertain protocol state, discard
or replace the connection rather than returning it as healthy.

Never return a connection to the pool while a transaction is still active,
failed, or unknown.

Nested transactions and savepoints must not appear implicitly. If support is
added, expose their semantics deliberately.

## Cancellation

Swift task cancellation is not sufficient by itself; the backend operation may
still be executing.

When backend cancellation is supported:

- signal the backend operation;
- keep cancellation transport work off event loops;
- avoid holding internal locks while performing potentially blocking
  cancellation I/O;
- ensure cancellation handles/resources are released exactly once;
- ensure the query operation and cancellation operation cannot race into
  double-completion;
- clean the physical connection before reuse.

Distinguish:

- task cancellation requested by the caller;
- server-side statement timeout;
- connection failure;
- protocol cancellation errors.

Do not collapse every timeout/error into `CancellationError` if the public
contract already distinguishes them.

## Deadlines and timeouts

When introducing timeouts, define which layer owns them:

- application deadline;
- pool acquisition timeout;
- database statement timeout;
- socket/connect timeout;
- migration lock timeout.

Avoid stacking timers that race without a clear precedence model.

Timeout errors must not leak secrets such as connection strings, passwords, or
full query values by default.

## Query binding

Prefer parameter binding over interpolating untrusted values into SQL.

Preserve driver-neutral value semantics for:

- null;
- booleans;
- integers;
- floating point;
- strings;
- UUIDs;
- bytes.

Do not silently coerce values in ways that lose precision.

If a backend-specific type cannot be represented losslessly, either:

- expose it as a documented neutral representation;
- require explicit decoding/conversion;
- provide an optional backend-specific escape hatch.

Never build SQL identifiers from user input without a separate identifier
validation/quoting strategy. Bound parameters are for values, not SQL grammar.

## Result decoding

Row decoding must have deterministic behavior for:

- missing columns;
- NULL values;
- duplicate column names;
- type mismatch;
- overflow;
- malformed textual representation;
- byte payload ownership.

Do not silently turn decoding failures into default values.

Avoid unnecessary copies for large byte values where the lifetime can be made
safe and measured, but never expose backend-owned memory after its validity
ends.

## Error normalization

Driver-neutral errors should preserve enough information for applications to
reason about failures without exposing backend internals unnecessarily.

Useful dimensions include:

- stable error kind;
- transient/retryable classification;
- backend code such as SQLSTATE when available;
- safe message;
- underlying cause for debugging when policy permits.

Do not include passwords or connection strings in public errors/logs.

Treat server-provided diagnostic strings as potentially containing query values.

## Retry discipline

Do not automatically retry arbitrary queries.

A retry can duplicate side effects.

Automatic retries are only safe when idempotency and transaction state are
proven.

If retry support is introduced, require an explicit policy and distinguish:

- connection establishment;
- read-only idempotent operation;
- transaction body;
- commit uncertainty.

An uncertain commit must not be blindly replayed.

## Services and dependency registry

Service registration should remain setup-time work.

Prefer resolving long-lived services during handler setup instead of performing
global dictionary/type-erased lookup on every request.

The service container must not become a hidden service locator reachable from
every layer.

Shutdown hooks should:

- run once;
- have deterministic ordering;
- propagate or report failure according to the documented policy;
- not leave pools or background workers alive after successful shutdown.

## Migrations

Migration systems must be deterministic and auditable.

Require:

- stable migration identifiers/order;
- duplicate detection;
- checksum/drift behavior when applicable;
- explicit up/down semantics if rollback is supported;
- transactional execution where the database and migration permit it;
- failure leaves the migration history consistent;
- concurrent migrators cannot silently apply the same migration twice.

Do not edit an already-applied migration casually.

Prefer a new migration over rewriting historical production state.

If migration locking is used, document backend scope and failure behavior.

Do not run migrations implicitly as a side effect of serving HTTP unless that is
an explicit product decision with startup-failure semantics.

## ORM rules

The ORM is a convenience layer over explicit database operations.

Avoid:

- implicit N+1 query behavior hidden behind property access;
- transparent network I/O from ordinary field access;
- runtime reflection on hot paths;
- automatically loading entire result sets without limits;
- silently selecting all columns when a narrower shape is available.

CRUD helpers should preserve explicit error, transaction, and cancellation
semantics.

If relationships or eager loading are added, make query count and loading
strategy visible to the caller.

## Memory and backpressure

Bound:

- pool size;
- wait queue size when practical;
- buffered result sizes or streaming batches;
- migration input;
- statement cache size;
- ORM identity/cache structures if introduced.

Do not load unbounded query results into memory by default.

For large-result streaming, define cancellation, connection lease lifetime,
consumer backpressure, and cleanup before implementation.

## Security

Persistence code must treat these as secrets or sensitive data:

- connection strings;
- passwords;
- TLS client keys;
- auth tokens;
- database rows containing application data;
- SQL parameters.

Do not log them by default.

Production PostgreSQL TLS configuration must not silently downgrade because a
convenience default hides backend behavior.

Do not implement custom cryptography in the persistence layer.

## Testing strategy

Use deterministic unit tests for driver-neutral contracts and real database
integration tests for behavior that depends on the server or libpq.

Cover applicable cases:

- pool saturation;
- waiter cancellation;
- connection replacement;
- shutdown with idle and leased connections;
- query success/error;
- NULL/type decoding;
- transaction commit;
- transaction rollback;
- task cancellation during query;
- rollback after cancellation;
- statement timeout;
- connection loss;
- migration ordering;
- migration failure;
- duplicate migration;
- ORM insert/read/update/delete;
- concurrent operations when supported.

A regression involving a platform system library should be tested on the
affected platform in addition to local tests.

Do not use sleeps when synchronization hooks or controlled server operations can
prove the state transition deterministically.

## Benchmarking

Use `.agents/skills/benchmark-validation/SKILL.md` for performance claims.

Separate at least:

- pool acquisition overhead;
- query execution dominated by database/server latency;
- row decode cost;
- ORM overhead above direct Database use;
- migration performance from request-path performance.

Do not claim framework speed from a benchmark dominated by localhost database
latency without isolating the layer of interest.

For connection-pool work, include contention and tail latency, not only
single-operation average latency.

For allocation optimizations, measure RSS/allocations in addition to throughput
when practical.

## Portability

Persistence adapters that use system libraries must also use
`.agents/skills/cross-platform-portability/SKILL.md`.

Pay special attention to:

- Darwin vs Glibc APIs;
- libpq version differences;
- socket and cancellation behavior;
- package discovery/pkg-config;
- TLS backend behavior;
- integer/C enum bridging.

A passing macOS test does not prove Linux behavior.

## Review checklist

Before approving persistence work, verify:

- event loops cannot block on database I/O;
- connection ownership is explicit;
- leases are returned exactly once;
- broken/uncertain connections are discarded;
- cancellation cannot double-complete;
- transactions clean up before connection reuse;
- parameter values are bound safely;
- errors do not expose secrets;
- retries cannot duplicate side effects;
- migrations preserve history consistency;
- ORM convenience does not hide accidental I/O;
- queues and caches are bounded;
- real-backend tests cover backend-dependent behavior;
- portability is validated for system-library changes.

## Stop conditions

Reject or redesign the change when:

- a database call can block an event-loop thread;
- a cancelled waiter can later receive a lease;
- a connection can return to the pool inside a failed transaction;
- cleanup ownership is ambiguous;
- cancellation performs blocking work while holding shared state locks;
- automatic retries can duplicate writes;
- SQL is built from untrusted value interpolation;
- migration history can diverge silently;
- ORM APIs hide uncontrolled network I/O;
- an optimization depends on weakening transaction or error semantics.
