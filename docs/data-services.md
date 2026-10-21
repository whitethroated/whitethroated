# WhiteThroated data services

Status: **experimental**

Phase 4 adds five independent data products. None of them is imported by the
core `WhiteThroated` target, and none changes the request path unless application
code explicitly calls it:

- `WhiteThroatedServices` — setup-time typed service registry and shutdown hooks.
- `WhiteThroatedDatabase` — driver-neutral query, row, transaction, and pool
  contract.
- `WhiteThroatedPostgres` — PostgreSQL adapter implemented directly on the
  system `libpq` client library.
- `WhiteThroatedMigrations` — ordered SQL migrations and the
  `whitethroated-migrate` executable.
- `WhiteThroatedORM` — explicit row models and CRUD repositories.

```text
WhiteThroatedServices (independent)
WhiteThroatedDatabase <-- WhiteThroatedPostgres (system libpq)
                     <-- WhiteThroatedMigrations
                     <-- WhiteThroatedORM
WhiteThroatedMigrationCLI --> Migrations + Postgres
```

The optional modules never depend on `WhiteThroatedRuntime` or on the core
framework. A database query is an ordinary opt-in async operation inside an
application handler; it does not add work to prepared, synchronous, or unrelated
routes.

## Requirements

The core framework does not need PostgreSQL. The adapter needs the system libpq
development files and `pkg-config`:

```text
# macOS (Homebrew; libpq is keg-only)
brew install libpq pkgconf
export PKG_CONFIG_PATH="$(brew --prefix libpq)/lib/pkgconfig"

# Debian/Ubuntu
apt-get install libpq-dev pkg-config
```

No PostgreSQL protocol implementation and no third-party database package is
included in the repository. `Sources/CPostgres` is a SwiftPM system-library
target whose header only declares the system interface.

## Services

`ServiceRegistry` is mutable only during setup. `start()` instantiates factories
once and returns an immutable `ServiceContainer`. Resolve services while
handlers are being configured rather than through a global lookup on every
request. Shutdown hooks run once, in reverse registration order, and support
async cleanup.

```swift
import WhiteThroatedDatabase
import WhiteThroatedServices

let databaseKey = ServiceKey<any Database>("database")
let registry = ServiceRegistry()

try registry.register(database, for: databaseKey)
try registry.onShutdown {
    try await database.shutdown()
}

let services = try registry.start()
let database = try services.require(databaseKey)
```

Registering the same key name twice is rejected even if the values have
different static types. The registry does not perform runtime reflection.

## Database contract

Queries use positional, one-based placeholders and `DatabaseValue` bindings:

```swift
let result = try await database.execute(
    DatabaseQuery(
        """
        SELECT "id", "name"
        FROM "users"
        WHERE "id" = $1
        """,
        bindings: [.int(42)]
    )
)

if let row = result.rows.first {
    let id = try row.decode("id", as: Int64.self)
    let name = try row.decode("name", as: String.self)
    print(id, name)
}
```

`Database` is safe to share across tasks. A connection lease exists for work
that must stay on one session:

```swift
let value = try await database.withConnection { connection in
    try await connection.execute(
        DatabaseQuery("SELECT current_database()")
    )
}
```

Transactions are explicit and always bounded:

```swift
let name = try await database.withTransaction { transaction in
    _ = try await transaction.execute(
        DatabaseQuery(
            """
            INSERT INTO "users" ("id", "name") VALUES ($1, $2)
            """,
            bindings: [.int(42), .string("Ada")]
        )
    )

    return "Ada"
}
```

If the body throws, the adapter rolls back. A cancelled task still attempts the
rollback on the same connection before the connection can return to the pool.
Nested transactions and savepoints are not part of this contract.

### Values and rows

`DatabaseValue` is driver-neutral: `null`, `bool`, `int`, `double`, `string`,
`uuid`, and `bytes`. The Postgres adapter maps common PostgreSQL types as
follows:

| PostgreSQL type | `DatabaseValue` |
| --- | --- |
| `boolean` | `.bool` |
| `smallint`, `integer`, `bigint`, `oid` | `.int` |
| `real`, `double precision` | `.double` |
| `uuid` | `.uuid` |
| `bytea` | `.bytes` |
| `numeric`, date/time, JSON, arrays, extension types | `.string` |

`numeric` intentionally stays a string to avoid silent precision loss. Use
`double precision` when a Swift `Double` is the intended representation. A
`DatabaseRow` is keyed by column name; duplicate names collapse to the last
column, so use explicit aliases when a query returns both values.

Text parameters use PostgreSQL type inference. Bind a `DatabaseValue.string`
to a UUID, enum, or other assignment-cast target without adding a manual cast
when the SQL context supplies the type. A bare `SELECT $1` with a string binding
has no context; add an explicit cast such as `$1::text`. Integer bindings are
sent as `bigint` and `Double` bindings as `double precision`; add `$1::integer`
or `$1::real` when a narrower type is required.

### Cancellation and errors

The contract is async/await and honors Swift task cancellation. The Postgres
adapter uses `PQcancel` when a Swift task is cancelled while a libpq call is in
flight, and removes a cancelled task from the pool's lease queue so it does not
wait for an unrelated connection. A server-side `statement_timeout` also
produces `DatabaseError.Kind.cancelled`, while task cancellation throws
`CancellationError`. With libpq versions before 17, `PQcancel` sends the cancel
request over a separate unencrypted connection even when the main connection
uses TLS; the request carries only the cancel key for the in-flight query.

Errors are normalized to `DatabaseError` with a stable kind, optional SQLSTATE,
and a transient flag. Constraint violations, syntax errors, cancelled
statements, transaction failures, and unavailable connections are classified
separately. The adapter does not add connection strings or passwords to errors;
server-provided error detail can still contain query values. libpq may also emit
server notices to stderr.

## PostgreSQL adapter

```swift
import WhiteThroatedPostgres

let database = try await PostgresDatabase.connect(
    configuration: PostgresConfiguration(
        connectionString: databaseURL,
        poolSize: 4
    )
)

// Register `database.shutdown()` with the application's lifecycle cleanup
// mechanism so the pool drains after request draining.
```

`connectionString` is passed to `PQconnectdb`, so it accepts a
`postgresql://` URI or a libpq keyword/value string. The adapter does not rewrite
SSL settings. libpq's default is `sslmode=prefer`, which can fall back to an
unencrypted connection; set `sslmode=require` or `sslmode=verify-full`
explicitly in production. `sslmode=disable` is intended only for a local
development server. Keep passwords out of logs and prefer an environment
variable or secret manager over `--database-url` in production.

### Blocking model

libpq is synchronous. Each leased physical connection owns one dedicated serial
`DispatchQueue`; every libpq call for that connection runs there. SwiftNIO event
loops are never used for database work and never wait synchronously for a query.
The pool is an actor that creates connections lazily, hands out leases, replaces
broken connections, and drains leased connections before shutdown. `poolSize` is
bounded from 1 to 64 and should be sized to the database's connection budget,
not to the number of HTTP requests.

The adapter opens and validates one connection during `connect`. Other
connections are opened on demand up to `poolSize`.

### Pool and transaction limits

- One SQL statement per `DatabaseQuery`. The extended query protocol does not
  accept multiple statements in one call.
- No prepared-statement cache, `COPY`, `LISTEN`/`NOTIFY`, savepoints, or
  streaming result sets yet.
- The Postgres session configuration is UTF-8 with `bytea_output=hex` and
  `standard_conforming_strings=on`.
- A broken connection is discarded rather than returned to the pool.
- `shutdown()` is idempotent and waits for outstanding pooled leases to be
  released. Migration lock connections are separate from the pool and close
  when their `withMigrationLock` scope ends.
- Do not start another lease from the same pool inside a lease body; use the
  connection passed to the body. The Postgres migration lock avoids this by
  holding its advisory lock on a dedicated connection outside the pool, so
  migration locking does not consume pool capacity.
- There is no connect or statement timeout beyond libpq/server defaults; set
  `connect_timeout` and `statement_timeout` in the connection string or server
  configuration for production workloads.

## Migrations

A migration file is one migration. Its filename without `.sql` is the ID; files
are applied in lexicographic order. Statements are split with support for
quoted strings, quoted identifiers, line comments, nested block comments, and
PostgreSQL dollar-quoted bodies. Unterminated strings, quoted identifiers, or
comments are rejected when the file is loaded. Each migration runs in its own
transaction and records a SHA-256 checksum in the tracking table.

```text
Migrations/
  001_create_users.sql
  002_add_users_email.sql
```

```swift
let migrations = try MigrationFileLoader.load(
    directory: "Migrations"
)

let runner = try MigrationRunner(
    database: database
)

let report = try await runner.migrate(migrations)
let status = try await runner.status(migrations)
```

`status` and the CLI's `--status` create the tracking table if it does not exist,
then report applied and pending IDs. `--dry-run` performs the same planning step
and reports what would be applied without running migration statements. A
changed migration file with an already-applied ID is rejected by checksum.

When the database implements `DatabaseMigrationLocking`, `migrate` (including a
dry run) holds a session-level advisory lock for the whole run. `status` only
reads and does not take the migration lock; concurrent `status` calls on a
database without the tracking table can race on its creation, so run `migrate`
first when that matters. The Postgres implementation holds
the lock on a dedicated connection outside the pool, so concurrent migration
runners cannot starve the connections that the lock holder needs; the CLI
default pool size is 4. The lock is keyed by the current database name and is
released explicitly, or by connection close after a crash.

Migration files can use dollar-quoted bodies and identifiers containing `$`.
SQL-standard `BEGIN ATOMIC` function bodies are not tracked by the statement
splitter and are not supported; write function bodies with dollar quoting
instead.

The `whitethroated-migrate` executable is separate from the server:

```text
swift build -c release --product whitethroated-migrate

DATABASE_URL='postgresql://user:password@host/db?sslmode=verify-full' \
  .build/release/whitethroated-migrate --status

DATABASE_URL='postgresql://user:password@host/db?sslmode=verify-full' \
  .build/release/whitethroated-migrate --dry-run

DATABASE_URL='postgresql://user:password@host/db?sslmode=verify-full' \
  .build/release/whitethroated-migrate
```

Options are `--database-url`, `--migrations`, `--table`, `--status`,
`--dry-run`, and `--help`. `DATABASE_URL` and `WHITETHROATED_DATABASE_URL` are
accepted as environment fallbacks. Exit code 2 indicates a usage error; exit
code 1 indicates a runtime or database error. There are no automatic down
migrations, and migrations never run automatically when the server starts.

## Minimum ORM

The ORM is explicit. Models declare their table, primary key, columns, and
row-decoding function. A repository precomputes quoted SQL during setup and
performs no query when a property is read. There is no active-record base class,
hidden global connection, lazy relationship, or implicit N+1 behavior.

```swift
import WhiteThroatedDatabase
import WhiteThroatedORM

struct User: DatabaseModel {
    static let tableName = "users"
    static let primaryKeyColumn = "id"
    static let columns = ["id", "name"]

    let id: Int64
    let name: String

    init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }

    init(databaseRow: DatabaseRow) throws {
        id = try databaseRow.decode("id", as: Int64.self)
        name = try databaseRow.decode("name", as: String.self)
    }

    func databaseValues() throws -> [String: DatabaseValue] {
        [
            "id": .int(id),
            "name": .string(name),
        ]
    }
}

let user = try await database.withConnection { connection in
    let users = try DatabaseRepository<User>(
        connection: connection
    )
    return try await users.find(42)
}

try await database.withTransaction { transaction in
    let users = try DatabaseRepository<User>(
        connection: transaction
    )
    try await users.insert(
        User(id: 43, name: "Grace")
    )
}
```

`DatabaseRepository` provides `all`, `find`, `insert`, `update`, and `delete`.
It requires at least one mutable column and a primary-key column included in
`columns`. The repository receives its connection explicitly, so a pool lease
and a transaction use the same operation surface.

## Testing

Unit tests cover value encoding, type mapping, error classification, migration
planning, and repository SQL without a database. Real-server tests are gated:

```text
WHITETHROATED_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable' \
  swift test -c release --filter PostgresIntegrationTests
```

Integration coverage includes bindings, nulls, UUID/bytea round trips,
transactions, rollback, constraint errors, in-flight and queued cancellation,
large bulk binding counts, concurrent pool use, session settings, migration
apply/status, concurrent migration locking, and idempotent shutdown. CI installs
`libpq-dev` and runs the release suite against a PostgreSQL service.

## Current boundaries

This is a Phase 4 proof, not a production database platform. Review these
before relying on it:

- no TLS policy override, connection retry policy, or health-check loop;
- no prepared-statement cache or binary parameter/result format;
- no `COPY`, replication, notification, or server-side cursor support;
- migration files must not contain transaction control (`BEGIN`, `COMMIT`,
  `ROLLBACK`); the runner owns the transaction and applies each file atomically;
- migration statements must be transactional, so `CREATE INDEX CONCURRENTLY`
  and `VACUUM` are not supported as migrations;
- `numeric` precision is preserved as text rather than a decimal Swift type;
- migrations are forward-only and have no automatic rollback;
- session-level changes such as `SET search_path` are not automatically reset
  between leases; put defaults in the connection string/options or reset within
  the lease;
- the adapter is a thin libpq boundary, not a reimplementation of the
  PostgreSQL protocol.
