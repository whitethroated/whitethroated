import WhiteThroatedDatabase

enum PostgresErrorMapper {
    static func connection(
        _ message: String
    ) -> DatabaseError {
        DatabaseError(
            kind: .unavailable,
            message: normalized(message),
            isTransient: true
        )
    }

    static func shutdown() -> DatabaseError {
        DatabaseError(
            kind: .unavailable,
            message: "Postgres connection pool is shut down"
        )
    }

    static func result(
        sqlState: String?,
        message: String
    ) -> DatabaseError {
        let state = sqlState ?? ""
        let kind: DatabaseError.Kind

        switch state {
        case "57014":
            kind = .cancelled

        case "23502", "23503", "23505", "23514", "23P01":
            kind = .constraint

        case "25006", "25P02", "40001", "40P01", "55P03":
            kind = .transaction

        case "42601", "42703", "42883", "42P01", "42P02", "42P07":
            kind = .syntax

        case "08000", "08001", "08003", "08004", "08006",
             "53300", "57P01", "57P02", "57P03":
            kind = .unavailable

        default:
            kind = .other
        }

        let transient =
            state == "40001"
            || state == "40P01"
            || state == "55P03"
            || state.hasPrefix("08")
            || state == "53300"
            || state == "57P01"
            || state == "57P02"
            || state == "57P03"

        return DatabaseError(
            kind: kind,
            message: normalized(message),
            code: sqlState,
            isTransient: transient
        )
    }

    static func mapping(
        _ message: String
    ) -> DatabaseError {
        DatabaseError(
            kind: .mapping,
            message: normalized(message)
        )
    }

    private static func normalized(
        _ message: String
    ) -> String {
        var message = message

        while message.last == "\n"
            || message.last == "\r"
        {
            message.removeLast()
        }

        return message.isEmpty
            ? "Unknown PostgreSQL error"
            : message
    }
}
