/// Configuration for the libpq-backed PostgreSQL adapter.
///
/// `connectionString` is passed directly to `PQconnectdb`, so it accepts either
/// a `postgresql://` URI or a libpq keyword/value connection string. The adapter
/// does not rewrite SSL settings: use `sslmode=verify-full` for production
/// deployments that require certificate and hostname verification.
public struct PostgresConfiguration:
    Sendable,
    Equatable
{
    public let connectionString: String
    public let poolSize: Int

    public init(
        connectionString: String,
        poolSize: Int = 4
    ) {
        precondition(
            !connectionString.isEmpty,
            "Postgres connection string must not be empty"
        )
        precondition(
            (1...64).contains(poolSize),
            "Postgres pool size must be between 1 and 64"
        )

        self.connectionString = connectionString
        self.poolSize = poolSize
    }
}
