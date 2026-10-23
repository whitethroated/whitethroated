# WhiteThroatedMigrations

Status: **experimental**

`WhiteThroatedMigrations` provides forward-only schema migrations for
Postgres-backed applications. It never runs automatically: migrations execute
when `MigrationRunner.migrate` is called from application setup or from the
`whitethroated-migrate` executable. There are no down migrations; correcting a
bad migration means applying a new one.

## Authoring

One SQL file is one migration. Its filename without the `.sql` extension is the
migration ID, and files are applied in lexicographic filename order. Every
statement in the file is executable against Postgres.

```text
Migrations/
  001_create_users.sql
  002_add_users_email.sql
```

```swift
let migrations = try MigrationFileLoader.load(
    directory: "Migrations"
)
```

`MigrationFileLoader` collects `*.sql` files from the directory, sorted by
filename. A file that fails to load aborts setup with
`MigrationFileError` (`unreadableDirectory`, `unreadableFile`, `invalidUTF8`,
`invalidSQL`, or `duplicateID` when two files would produce the same ID).
Unterminated strings, quoted identifiers, or comments are invalid SQL and are
rejected at load time. Statement splitting supports quoted strings, quoted
identifiers, line comments, nested block comments, and PostgreSQL
dollar-quoted bodies; SQL-standard `BEGIN ATOMIC` function bodies are not
tracked by the splitter — write function bodies with dollar quoting instead.

Each `Migration` carries its SHA-256 checksum, computed over the executable
statements with every statement length-prefixed, so different statement
boundaries can never produce the same checksum input. Comments and surrounding
whitespace removed by the splitter are not part of the checksum. Editing a
file after the database has applied it changes the checksum, which aborts
planning (see failure semantics below) — create a new migration instead.

## Running

```swift
import WhiteThroatedDatabase
import WhiteThroatedMigrations
import WhiteThroatedPostgres

let database = try await PostgresDatabase.connect(
    configuration: PostgresConfiguration(
        connectionString: databaseURL
    )
)

let runner = try MigrationRunner(
    database: database,
    tableName: "_whitethroated_migrations"
)

let report = try await runner.migrate(migrations)
// or: runner.migrate(migrations, dryRun: true)
// or: runner.status(migrations)
```

`tableName` defaults to `_whitethroated_migrations` and must not be empty or
contain a NUL byte. The runner validates that all provided IDs are unique and
creates the tracking table with `id` (primary key), `checksum`, and
`applied_at` columns before reading history. A corrupt history is surfaced as
`MigrationError` (`duplicateAppliedMigration` for double-recorded IDs,
`appliedMigrationNotProvided` for an applied ID that is not in the provided
set, `malformedAppliedMigration` for an unreadable record).

Planning splits migrations into already-applied ones (**skipped**) and the rest
(**pending**). Pending migrations are applied in ascending ID order regardless
of caller-provided input, so recorded history is deterministic.
`MigrationReport` reports the `applied` IDs of this run (or the ones a dry run
would apply), the `skipped` IDs, and whether it was a dry run.
`MigrationStatus` (from `status`) lists `applied` and `pending` IDs without
applying anything.

## Failure semantics

Every pending migration runs inside its own transaction together with the
tracking-table insert: either the statements and the ID record commit, or
nothing does. If a statement fails, that migration rolls back completely — its
ID is not recorded, so the next `migrate` retries it — while earlier
migrations of the same run stay applied. Committed prefixes of a failed
migration's own statements are never left behind.

A migration whose ID is recorded with a different checksum than the provided
file aborts planning with `MigrationError.checksumMismatch(id:recorded:computed:)`
before any statement runs. Recovery is a deliberate operation out of scope of
the module: restore a matching file, or remove the record and apply an agreed
replacement.

## Locking

When the connected database implements `DatabaseMigrationLocking`, `migrate` —
including dry runs — holds a migration lock for the whole run so concurrent
runners cannot interleave. `status` only reads and does not take the lock. The
Postgres implementation holds a session-level advisory lock on a dedicated
connection outside the pool (so runners do not consume pool capacity), keyed
by the current database name. The lock is released explicitly at the end of
the run, or by connection close if the process crashes. See
[Data services](data-services.md#migrations) for the pool behavior and
transaction limits around this.

## CLI

The migration runner ships as the `whitethroated-migrate` executable, separate
from the server:

```text
swift build -c release --product whitethroated-migrate

DATABASE_URL='postgresql://user:password@host/db?sslmode=verify-full' \
  .build/release/whitethroated-migrate --status

DATABASE_URL='postgresql://user:password@host/db?sslmode=verify-full' \
  .build/release/whitethroated-migrate --dry-run

DATABASE_URL='postgresql://user:password@host/db?sslmode=verify-full' \
  .build/release/whitethroated-migrate
```

Invoking it without a mode applies pending migrations.

| Option | Meaning |
| --- | --- |
| `--database-url <url>` | Postgres URL; defaults to `DATABASE_URL`, then `WHITETHROATED_DATABASE_URL` |
| `--migrations <path>` | Directory containing `*.sql` files; defaults to `./Migrations` |
| `--table <name>` | Tracking table; defaults to `_whitethroated_migrations` |
| `--status` | Print applied and pending IDs; change nothing |
| `--dry-run` | Print migrations that would be applied; change nothing |
| `--help`, `-h` | Print usage |

Values can also be passed inline (`--migrations=./Migrations`,
`--table=my_migrations`, `--database-url=...`). `--status` and `--dry-run`
cannot be combined.

Status output lists `Applied:` and `Pending:` IDs. Apply output lists
`Applied:` and `Skipped:` IDs; dry-run output lists `Would apply:` and
`Skipped:`, followed by `Dry run: no changes were committed`. Usage errors
(conflicting modes, missing URL or value, unexpected arguments) write the
message to stderr and exit with code 2; runtime and database errors exit with
code 1.
