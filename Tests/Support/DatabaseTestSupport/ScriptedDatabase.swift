import NIOConcurrencyHelpers
import WhiteThroatedDatabase

/// Test database that records every query and delegates results to a closure.
public final class ScriptedDatabase:
    Database,
    Sendable
{
    public typealias Handler =
        @Sendable (
            DatabaseQuery
        ) async throws -> DatabaseQueryResult

    private struct State: Sendable {
        var queries: [DatabaseQuery] = []
        var isShutdown = false
    }

    private let handler: Handler
    private let state =
        NIOLockedValueBox(State())

    public init(
        handler: @escaping Handler
    ) {
        self.handler = handler
    }

    public var recordedQueries: [DatabaseQuery] {
        state.withLockedValue {
            $0.queries
        }
    }

    public var isShutdown: Bool {
        state.withLockedValue {
            $0.isShutdown
        }
    }

    public func execute(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult {
        state.withLockedValue {
            $0.queries.append(query)
        }

        return try await handler(query)
    }

    public func withConnection<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseConnection
        ) async throws -> T
    ) async throws -> T {
        try await body(self)
    }

    public func withTransaction<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseTransaction
        ) async throws -> T
    ) async throws -> T {
        _ = try await execute(
            DatabaseQuery("BEGIN")
        )

        do {
            let value = try await body(
                ScriptedTransaction(
                    database: self
                )
            )

            _ = try await execute(
                DatabaseQuery("COMMIT")
            )

            return value
        } catch {
            _ = try? await execute(
                DatabaseQuery("ROLLBACK")
            )
            throw error
        }
    }

    public func shutdown() async throws {
        state.withLockedValue {
            $0.isShutdown = true
        }
    }
}

public struct ScriptedTransaction:
    DatabaseTransaction,
    Sendable
{
    private let database:
        ScriptedDatabase

    public init(
        database: ScriptedDatabase
    ) {
        self.database = database
    }

    public func execute(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult {
        try await database.execute(query)
    }

    public func withTransaction<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseTransaction
        ) async throws -> T
    ) async throws -> T {
        try await database
            .withTransaction(body)
    }
}
