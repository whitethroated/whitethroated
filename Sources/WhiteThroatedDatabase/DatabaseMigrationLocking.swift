/// Optional database capability used to serialize work that must not run
/// concurrently across processes, such as schema migrations.
///
/// The lock must stay on one session for the entire body. A Postgres adapter
/// can implement this with a session-level advisory lock held on a dedicated
/// connection that does not compete with pooled connections.
public protocol DatabaseMigrationLocking:
    Sendable
{
    func withMigrationLock<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T
}
