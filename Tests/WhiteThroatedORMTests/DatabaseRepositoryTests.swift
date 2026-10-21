import WhiteThroatedDatabase
import WhiteThroatedDatabaseTestSupport
import WhiteThroatedORM
import XCTest

private struct User: DatabaseModel {
    static let tableName = "users"
    static let primaryKeyColumn = "id"
    static let columns = [
        "id",
        "email",
        "active",
    ]

    let id: Int
    let email: String
    let active: Bool

    init(
        id: Int,
        email: String,
        active: Bool
    ) {
        self.id = id
        self.email = email
        self.active = active
    }

    init(
        databaseRow: DatabaseRow
    ) throws {
        self.id = try databaseRow.decode(
            "id",
            as: Int.self
        )
        self.email = try databaseRow.decode(
            "email",
            as: String.self
        )
        self.active = try databaseRow.decode(
            "active",
            as: Bool.self
        )
    }

    func databaseValues() throws
        -> [String: DatabaseValue]
    {
        [
            "id": id.databaseValue,
            "email": email.databaseValue,
            "active": active.databaseValue,
        ]
    }
}

private struct EmptyModel: DatabaseModel {
    typealias ID = Int

    static let tableName = "empty"
    static let primaryKeyColumn = "id"
    static let columns: [String] = []

    var id: Int { 0 }

    init(databaseRow: DatabaseRow) throws {}

    func databaseValues() throws
        -> [String: DatabaseValue]
    {
        [:]
    }
}

private struct DuplicateModel: DatabaseModel {
    typealias ID = Int

    static let tableName = "duplicate"
    static let primaryKeyColumn = "id"
    static let columns = [
        "id",
        "id",
    ]

    var id: Int { 0 }

    init(databaseRow: DatabaseRow) throws {}

    func databaseValues() throws
        -> [String: DatabaseValue]
    {
        ["id": .int(0)]
    }
}

private struct MissingPrimaryKeyModel: DatabaseModel {
    typealias ID = Int

    static let tableName = "missing"
    static let primaryKeyColumn = "id"
    static let columns = ["name"]

    var id: Int { 0 }

    init(databaseRow: DatabaseRow) throws {}

    func databaseValues() throws
        -> [String: DatabaseValue]
    {
        ["name": .string("x")]
    }
}

private struct ImmutableModel: DatabaseModel {
    typealias ID = Int

    static let tableName = "immutable"
    static let primaryKeyColumn = "id"
    static let columns = ["id"]

    let id: Int

    init(id: Int) {
        self.id = id
    }

    init(databaseRow: DatabaseRow) throws {
        self.id = try databaseRow.decode(
            "id",
            as: Int.self
        )
    }

    func databaseValues() throws
        -> [String: DatabaseValue]
    {
        ["id": id.databaseValue]
    }
}

final class DatabaseRepositoryTests: XCTestCase {
    func testSelectAllUsesPrecomputedQuotedSQL()
        async throws
    {
        let database =
            ScriptedDatabase {
                query in

                XCTAssertEqual(
                    query.sql,
                    "SELECT \"id\", \"email\", \"active\" FROM \"users\""
                )
                XCTAssertEqual(query.bindings, [])

                return DatabaseQueryResult(
                    rows: [
                        [
                            "id": .int(1),
                            "email":
                                .string("a@example.com"),
                            "active": .bool(true),
                        ]
                    ],
                    affectedRows: 1
                )
            }
        let repository =
            try DatabaseRepository(
                connection: database,
                model: User.self
            )

        let users =
            try await repository.all()

        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].id, 1)
        XCTAssertEqual(
            users[0].email,
            "a@example.com"
        )
        XCTAssertTrue(users[0].active)
    }

    func testFindBindsPrimaryKeyAndReturnsNil()
        async throws
    {
        let database =
            ScriptedDatabase {
                query in

                XCTAssertEqual(
                    query.sql,
                    """
                    SELECT "id", "email", "active" \
                    FROM "users" WHERE "id" = $1 LIMIT 1
                    """
                )
                XCTAssertEqual(
                    query.bindings,
                    [.int(7)]
                )

                return .empty
            }
        let repository =
            try DatabaseRepository(
                connection: database,
                model: User.self
            )

        let user =
            try await repository.find(7)

        XCTAssertNil(user)
    }

    func testInsertBindsDeclaredColumnsInOrder()
        async throws
    {
        let database =
            ScriptedDatabase {
                query in

                XCTAssertEqual(
                    query.sql,
                    """
                    INSERT INTO "users" ("id", "email", "active") \
                    VALUES ($1, $2, $3)
                    """
                )
                XCTAssertEqual(
                    query.bindings,
                    [
                        .int(4),
                        .string("b@example.com"),
                        .bool(false),
                    ]
                )

                return DatabaseQueryResult(
                    rows: [],
                    affectedRows: 1
                )
            }
        let repository =
            try DatabaseRepository(
                connection: database,
                model: User.self
            )
        let result =
            try await repository.insert(
                User(
                    id: 4,
                    email: "b@example.com",
                    active: false
                )
            )

        XCTAssertEqual(result.affectedRows, 1)
    }

    func testUpdateExcludesPrimaryKeyFromSet()
        async throws
    {
        let database =
            ScriptedDatabase {
                query in

                XCTAssertEqual(
                    query.sql,
                    """
                    UPDATE "users" SET "email" = $1, "active" = $2 \
                    WHERE "id" = $3
                    """
                )
                XCTAssertEqual(
                    query.bindings,
                    [
                        .string("new@example.com"),
                        .bool(true),
                        .int(9),
                    ]
                )

                return DatabaseQueryResult(
                    rows: [],
                    affectedRows: 1
                )
            }
        let repository =
            try DatabaseRepository(
                connection: database,
                model: User.self
            )

        _ = try await repository.update(
            User(
                id: 9,
                email: "new@example.com",
                active: true
            )
        )
    }

    func testDeleteBindsPrimaryKey() async throws {
        let database =
            ScriptedDatabase {
                query in

                XCTAssertEqual(
                    query.sql,
                    """
                    DELETE FROM "users" WHERE "id" = $1
                    """
                )
                XCTAssertEqual(
                    query.bindings,
                    [.int(9)]
                )

                return DatabaseQueryResult(
                    rows: [],
                    affectedRows: 1
                )
            }
        let repository =
            try DatabaseRepository(
                connection: database,
                model: User.self
            )

        let result =
            try await repository.delete(9)
        XCTAssertEqual(result.affectedRows, 1)
    }

    func testRepositoryCanUseATransaction()
        async throws
    {
        let database =
            ScriptedDatabase { _ in
                .empty
            }

        try await database.withTransaction {
            transaction in

            let repository =
                try DatabaseRepository(
                    connection: transaction,
                    model: User.self
                )
            _ = try await repository.insert(
                User(
                    id: 1,
                    email: "tx@example.com",
                    active: true
                )
            )
        }

        XCTAssertEqual(
            database.recordedQueries.map(\.sql),
            [
                "BEGIN",
                """
                INSERT INTO "users" ("id", "email", "active") \
                VALUES ($1, $2, $3)
                """,
                "COMMIT",
            ]
        )
    }

    func testInvalidSchemasAreRejected() {
        let database =
            ScriptedDatabase { _ in
                .empty
            }

        XCTAssertThrowsError(
            try DatabaseRepository(
                connection: database,
                model: EmptyModel.self
            )
        ) {
            XCTAssertEqual(
                $0 as? DatabaseRepositoryError,
                .emptyColumns
            )
        }

        XCTAssertThrowsError(
            try DatabaseRepository(
                connection: database,
                model: DuplicateModel.self
            )
        ) {
            XCTAssertEqual(
                $0 as? DatabaseRepositoryError,
                .duplicateColumn("id")
            )
        }

        XCTAssertThrowsError(
            try DatabaseRepository(
                connection: database,
                model: MissingPrimaryKeyModel.self
            )
        ) {
            XCTAssertEqual(
                $0 as? DatabaseRepositoryError,
                .primaryKeyNotInColumns("id")
            )
        }

        XCTAssertThrowsError(
            try DatabaseRepository(
                connection: database,
                model: ImmutableModel.self
            )
        ) {
            XCTAssertEqual(
                $0 as? DatabaseRepositoryError,
                .noMutableColumns
            )
        }
    }
}
