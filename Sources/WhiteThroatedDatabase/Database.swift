/// A leased database connection.
///
/// A connection executes queries and owns transaction boundaries. The
/// transaction wrapper rolls back automatically when its body throws, so
/// callers never receive a transaction that can be forgotten in an open state.
/// Run at most one transaction at a time on a connection; do not nest or
/// interleave `withTransaction` on the same connection.
public protocol DatabaseConnection:
    Sendable
{
    func execute(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult

    func withTransaction<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseTransaction
        ) async throws -> T
    ) async throws -> T
}

/// A connection scoped to an active transaction.
public protocol DatabaseTransaction:
    DatabaseConnection {}

/// A pool-backed database handle.
///
/// `Database` itself is safe to use concurrently. ``withConnection`` leases one
/// connection for work that must stay on the same session, such as advisory
/// locks. ``withTransaction`` leases a connection and commits or rolls back
/// around the supplied body.
///
/// Do not start another lease on the same `Database` from inside a lease body;
/// use the connection passed to the body. A pool with one connection would
/// deadlock waiting for the lease to be returned.
///
/// Implementations must propagate Swift task cancellation where the backend
/// supports it. ``shutdown()`` must be idempotent and must drain or close
/// pooled connections.
public protocol Database:
    DatabaseConnection
{
    func withConnection<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseConnection
        ) async throws -> T
    ) async throws -> T

    func shutdown() async throws
}

public extension DatabaseConnection {
    func execute(
        _ sql: String,
        _ bindings: [DatabaseValue] = []
    ) async throws -> DatabaseQueryResult {
        try await execute(
            DatabaseQuery(
                sql,
                bindings: bindings
            )
        )
    }
}

public extension Database {
    func withTransaction<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseTransaction
        ) async throws -> T
    ) async throws -> T {
        try await withConnection {
            connection in

            try await connection
                .withTransaction(body)
        }
    }
}
