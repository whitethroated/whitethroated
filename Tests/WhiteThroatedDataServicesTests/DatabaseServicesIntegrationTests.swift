import WhiteThroatedDatabase
import WhiteThroatedDatabaseTestSupport
import WhiteThroatedServices
import XCTest

final class DatabaseServicesIntegrationTests:
    XCTestCase
{
    func testServiceRegistryResolvesDatabaseAndOwnsShutdown()
        async throws
    {
        let database = ScriptedDatabase { query in
            XCTAssertEqual(
                query.sql,
                "SELECT $1"
            )
            XCTAssertEqual(
                query.bindings,
                [.int(42)]
            )

            return DatabaseQueryResult(
                rows: [
                    [
                        "value": .int(42),
                    ],
                ]
            )
        }

        let key = ServiceKey<any Database>(
            "database"
        )
        let registry = ServiceRegistry()

        try registry.register(
            database as any Database,
            for: key
        )
        try registry.onShutdown {
            try await database.shutdown()
        }

        let container = try registry.start()
        let resolved = try container.require(key)

        let result = try await resolved.execute(
            DatabaseQuery(
                "SELECT $1",
                bindings: [.int(42)]
            )
        )

        XCTAssertEqual(
            try result.rows.first?
                .decode("value", as: Int64.self),
            42
        )
        XCTAssertEqual(
            database.recordedQueries,
            [
                DatabaseQuery(
                    "SELECT $1",
                    bindings: [.int(42)]
                ),
            ]
        )
        XCTAssertFalse(database.isShutdown)

        try await container.shutdown()

        XCTAssertTrue(database.isShutdown)
    }
}
