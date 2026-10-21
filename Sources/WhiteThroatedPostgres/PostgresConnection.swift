import CPostgres
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import WhiteThroatedDatabase

/// A libpq connection whose blocking calls are confined to one serial queue.
///
/// `@unchecked Sendable` is justified by confinement and locks: `handle` is
/// accessed only from `queue`, `queue` is immutable, and `broken`/`closed` use
/// locked value boxes. ``invalidate()`` only flips a locked flag.
internal final class PostgresConnection:
    DatabaseConnection,
    @unchecked Sendable
{
    private static let queueCounter =
        NIOLockedValueBox(0)

    private let queue: DispatchQueue
    private let broken =
        NIOLockedValueBox(false)
    private let closed =
        NIOLockedValueBox(false)

    // Accessed only from `queue`.
    private var handle: OpaquePointer?

    private init(
        configuration: PostgresConfiguration
    ) {
        let number =
            Self.queueCounter.withLockedValue {
                value in

                value += 1
                return value
            }

        self.queue = DispatchQueue(
            label:
                "whitethroated.postgres.connection.\(number)",
            qos: .userInitiated
        )
    }

    static func connect(
        configuration: PostgresConfiguration
    ) async throws -> PostgresConnection {
        let connection =
            PostgresConnection(
                configuration: configuration
            )

        try await connection.open(
            configuration: configuration
        )

        return connection
    }

    var isBroken: Bool {
        broken.withLockedValue {
            $0
        }
    }

    var isClosed: Bool {
        closed.withLockedValue {
            $0
        }
    }

    func execute(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult {
        try await execute(
            query,
            honorCancellation: true
        )
    }

    func executeWithoutCancellation(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult {
        try await execute(
            query,
            honorCancellation: false
        )
    }

    func invalidate() {
        broken.withLockedValue {
            $0 = true
        }
    }

    func withTransaction<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseTransaction
        ) async throws -> T
    ) async throws -> T {
        _ = try await execute(
            DatabaseQuery("BEGIN")
        )

        do {
            let value = try await body(
                PostgresTransaction(
                    connection: self
                )
            )

            _ = try await execute(
                DatabaseQuery("COMMIT")
            )

            return value
        } catch let bodyError {
            // A cancelled task must still attempt rollback. The rollback is
            // deliberately not cancellation-aware so the connection does not
            // return to the pool inside a failed transaction.
            do {
                _ = try await execute(
                    DatabaseQuery("ROLLBACK"),
                    honorCancellation: false
                )
            } catch {
                invalidate()
            }
            throw bodyError
        }
    }

    func close() async {
        await withCheckedContinuation {
            continuation in

            queue.async { [self] in
                if let handle {
                    PQfinish(handle)
                    self.handle = nil
                }

                closed.withLockedValue {
                    $0 = true
                }
                broken.withLockedValue {
                    $0 = true
                }
                continuation.resume()
            }
        }
    }

    /// Roll back a transaction left open by application code before the
    /// connection returns to the pool. A connection leaked inside a failed
    /// transaction must never serve the next request.
    func prepareForRelease() async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in

            queue.async { [self] in
                defer {
                    continuation.resume()
                }

                guard
                    !isClosed,
                    let handle
                else {
                    return
                }

                let status =
                    PQtransactionStatus(handle)

                switch status {
                case PQTRANS_INTRANS, PQTRANS_INERROR:
                    if simpleCommand(
                        "ROLLBACK",
                        handle: handle
                    ) != nil
                    {
                        broken.withLockedValue {
                            $0 = true
                        }
                    } else if PQtransactionStatus(handle)
                        != PQTRANS_IDLE
                    {
                        broken.withLockedValue {
                            $0 = true
                        }
                    }

                case PQTRANS_IDLE:
                    if PQstatus(handle) != CONNECTION_OK {
                        broken.withLockedValue {
                            $0 = true
                        }
                    }

                default:
                    broken.withLockedValue {
                        $0 = true
                    }
                }
            }
        }
    }

    private func open(
        configuration: PostgresConfiguration
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            queue.async { [self] in
                let raw = configuration
                    .connectionString
                    .withCString {
                        PQconnectdb($0)
                    }

                guard let raw else {
                    continuation.resume(
                        throwing:
                            PostgresErrorMapper
                                .connection(
                                    "libpq could not allocate a connection"
                                )
                    )
                    return
                }

                guard PQstatus(raw) == CONNECTION_OK else {
                    let message =
                        errorMessage(raw)
                    PQfinish(raw)
                    continuation.resume(
                        throwing:
                            PostgresErrorMapper
                                .connection(message)
                    )
                    return
                }

                guard PQsetClientEncoding(
                    raw,
                    "UTF8"
                ) == 0 else {
                    let message =
                        errorMessage(raw)
                    PQfinish(raw)
                    continuation.resume(
                        throwing:
                            PostgresErrorMapper
                                .connection(
                                    "Could not set client encoding to UTF8: \(message)"
                                )
                    )
                    return
                }

                if let error = simpleCommand(
                    """
                    SET bytea_output TO 'hex';
                    SET standard_conforming_strings TO 'on'
                    """,
                    handle: raw
                ) {
                    PQfinish(raw)
                    continuation.resume(
                        throwing: error
                    )
                    return
                }

                self.handle = raw
                continuation.resume()
            }
        }
    }

    private func execute(
        _ query: DatabaseQuery,
        honorCancellation: Bool
    ) async throws -> DatabaseQueryResult {
        guard
            !query.sql.utf8.contains(0)
        else {
            throw PostgresErrorMapper.mapping(
                "SQL must not contain a NUL byte"
            )
        }

        if honorCancellation {
            try Task.checkCancellation()
        }

        let parameters =
            try query.bindings.map {
                try PostgresValueCodec
                    .parameter($0)
            }

        if honorCancellation {
            let cancellation =
                PostgresCancellationState()

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    continuation in

                    queue.async { [self] in
                        executeOnQueue(
                            query,
                            parameters: parameters,
                            cancellation: cancellation,
                            continuation: continuation
                        )
                    }
                }
            } onCancel: {
                cancellation.requestCancel()
            }
        }

        return try await withCheckedThrowingContinuation {
            continuation in

            queue.async { [self] in
                executeOnQueue(
                    query,
                    parameters: parameters,
                    cancellation: nil,
                    continuation: continuation
                )
            }
        }
    }

    private func executeOnQueue(
        _ query: DatabaseQuery,
        parameters: [PostgresParameter],
        cancellation: PostgresCancellationState?,
        continuation: CheckedContinuation<
            DatabaseQueryResult,
            Error
        >
    ) {
        guard !isClosed else {
            continuation.resume(
                throwing:
                    PostgresErrorMapper
                        .shutdown()
            )
            return
        }

        guard !isBroken else {
            continuation.resume(
                throwing:
                    PostgresErrorMapper
                        .connection(
                            "Postgres connection is no longer usable"
                        )
            )
            return
        }

        guard let handle else {
            continuation.resume(
                throwing:
                    PostgresErrorMapper
                        .shutdown()
            )
            return
        }

        cancellation?.install(
            PQgetCancel(handle)
        )

        if cancellation?.isCancelRequested
            == true
        {
            cancellation?.finish()
            continuation.resume(
                throwing: CancellationError()
            )
            return
        }

        let executionResult:
            OpaquePointer? =
                withParameterPointers(
                    parameters
                ) {
                    pointers,
                    types in

                    query.sql.withCString {
                        sql in

                        PQexecParams(
                            handle,
                            sql,
                            Int32(parameters.count),
                            parameters.isEmpty
                                ? nil
                                : types.baseAddress,
                            parameters.isEmpty
                                ? nil
                                : pointers.baseAddress,
                            nil,
                            nil,
                            0
                        )
                    }
                }

        guard let result = executionResult else {
            cancellation?.finish()
            broken.withLockedValue {
                $0 = true
            }
            continuation.resume(
                throwing:
                    PostgresErrorMapper
                        .connection(
                            errorMessage(handle)
                        )
            )
            return
        }

        let cancelRequested =
            cancellation?.isCancelRequested
            ?? false
        cancellation?.finish()

        defer {
            PQclear(result)
        }

        let status =
            PQresultStatus(result)

        if status == PGRES_TUPLES_OK
            || status == PGRES_SINGLE_TUPLE
        {
            do {
                let rows =
                    try mapRows(result)

                if PQstatus(handle)
                    != CONNECTION_OK
                {
                    broken.withLockedValue {
                        $0 = true
                    }
                }

                continuation.resume(
                    returning:
                        DatabaseQueryResult(
                            rows: rows
                        )
                )
            } catch {
                continuation.resume(
                    throwing: error
                )
            }

            return
        }

        if status == PGRES_COMMAND_OK
            || status == PGRES_EMPTY_QUERY
        {
            if PQstatus(handle)
                != CONNECTION_OK
            {
                broken.withLockedValue {
                    $0 = true
                }
            }

            continuation.resume(
                returning:
                    DatabaseQueryResult(
                        rows: [],
                        affectedRows:
                            affectedRows(result)
                    )
            )
            return
        }

        if PQstatus(handle)
            != CONNECTION_OK
        {
            broken.withLockedValue {
                $0 = true
            }
        }

        if status == PGRES_BAD_RESPONSE
            || status == PGRES_COPY_OUT
            || status == PGRES_COPY_IN
            || status == PGRES_COPY_BOTH
        {
            // COPY and malformed protocol responses leave libpq in a state that
            // this adapter does not drive. Discard the session instead of
            // returning it to the pool.
            broken.withLockedValue {
                $0 = true
            }
        }

        if cancelRequested,
           sqlState(result) == "57014"
        {
            continuation.resume(
                throwing: CancellationError()
            )
            return
        }

        if sqlState(result) == nil,
           PQstatus(handle) != CONNECTION_OK
        {
            // The server sent no SQLSTATE, so the result is not a classified
            // server error. Treat it as a transient connection failure instead
            // of an unknown query error.
            continuation.resume(
                throwing:
                    PostgresErrorMapper
                        .connection(
                            errorMessage(handle)
                        )
            )
            return
        }

        continuation.resume(
            throwing:
                resultError(
                    result,
                    handle: handle
                )
        )
    }

    private func mapRows(
        _ result: OpaquePointer
    ) throws -> [DatabaseRow] {
        let rowCount =
            Int(
                PQntuples(result)
            )
        let fieldCount =
            Int(
                PQnfields(result)
            )

        guard rowCount >= 0, fieldCount >= 0 else {
            throw PostgresErrorMapper.mapping(
                "PostgreSQL returned an invalid result shape"
            )
        }

        var columns:
            [(name: String, type: Oid)] = []
        columns.reserveCapacity(
            fieldCount
        )

        for field in 0..<fieldCount {
            guard
                let name = PQfname(
                    result,
                    Int32(field)
                )
            else {
                throw PostgresErrorMapper.mapping(
                    "PostgreSQL returned an unnamed column"
                )
            }

            columns.append(
                (
                    String(cString: name),
                    PQftype(
                        result,
                        Int32(field)
                    )
                )
            )
        }

        var rows:
            [DatabaseRow] = []
        rows.reserveCapacity(
            rowCount
        )

        for row in 0..<rowCount {
            var values:
                [String: DatabaseValue] = [:]
            values.reserveCapacity(
                fieldCount
            )

            for field in 0..<fieldCount {
                let column =
                    columns[field]

                if PQgetisnull(
                    result,
                    Int32(row),
                    Int32(field)
                ) != 0
                {
                    values[column.name] =
                        .null
                    continue
                }

                let length =
                    Int(
                        PQgetlength(
                            result,
                            Int32(row),
                            Int32(field)
                        )
                    )

                guard
                    length >= 0,
                    let raw = PQgetvalue(
                        result,
                        Int32(row),
                        Int32(field)
                    )
                else {
                    throw PostgresErrorMapper.mapping(
                        "PostgreSQL returned an invalid value"
                    )
                }

                let bytes =
                    UnsafeBufferPointer(
                        start:
                            UnsafeRawPointer(raw)
                                .assumingMemoryBound(
                                    to: UInt8.self
                                ),
                        count: length
                    )

                values[column.name] =
                    try PostgresValueCodec
                        .value(
                            type: column.type,
                            bytes: bytes
                        )
            }

            rows.append(
                DatabaseRow(values)
            )
        }

        return rows
    }

    private func affectedRows(
        _ result: OpaquePointer
    ) -> Int? {
        guard
            let tag = PQcmdTuples(result),
            tag.pointee != 0
        else {
            return nil
        }

        return Int(
            String(cString: tag)
        )
    }

    private func resultError(
        _ result: OpaquePointer,
        handle: OpaquePointer
    ) -> DatabaseError {
        let message: String

        if let pointer = PQresultErrorMessage(result) {
            message = String(cString: pointer)
        } else {
            message = errorMessage(handle)
        }

        return PostgresErrorMapper.result(
            sqlState: sqlState(result),
            message: message
        )
    }

    private func sqlState(
        _ result: OpaquePointer
    ) -> String? {
        guard
            let pointer = PQresultErrorField(
                result,
                Int32(WT_PG_DIAG_SQLSTATE)
            )
        else {
            return nil
        }

        return String(cString: pointer)
    }

    private func simpleCommand(
        _ sql: String,
        handle: OpaquePointer
    ) -> DatabaseError? {
        guard
            let result = sql.withCString({
                PQexec(handle, $0)
            })
        else {
            return PostgresErrorMapper.connection(
                errorMessage(handle)
            )
        }

        defer {
            PQclear(result)
        }

        let status =
            PQresultStatus(result)

        if status == PGRES_COMMAND_OK
            || status == PGRES_TUPLES_OK
            || status == PGRES_EMPTY_QUERY
        {
            return nil
        }

        return resultError(
            result,
            handle: handle
        )
    }

    private func errorMessage(
        _ handle: OpaquePointer
    ) -> String {
        guard let pointer = PQerrorMessage(handle) else {
            return "Unknown PostgreSQL connection error"
        }

        return String(cString: pointer)
    }

    private func withParameterPointers<R>(
        _ parameters: [PostgresParameter],
        _ body: (
            UnsafeBufferPointer<
                UnsafePointer<CChar>?
            >,
            UnsafeBufferPointer<Oid>
        ) -> R
    ) -> R {
        let types =
            parameters.map(\.type)

        // Marshal all bindings into one contiguous, NUL-terminated arena.
        // The previous per-binding recursion used one stack frame and one
        // array copy per parameter, which overflowed the connection queue's
        // stack for bulk statements with a few thousand bindings.
        var arena: [CChar] = []
        var offsets:
            [Int?] = []
        arena.reserveCapacity(
            parameters.reduce(0) {
                $0
                    + ($1.text?.utf8.count ?? 0)
                    + 1
            }
        )
        offsets.reserveCapacity(
            parameters.count
        )

        for parameter in parameters {
            guard
                let text = parameter.text
            else {
                offsets.append(nil)
                continue
            }

            offsets.append(
                arena.count
            )

            for byte in text.utf8 {
                arena.append(
                    CChar(
                        bitPattern: byte
                    )
                )
            }

            arena.append(0)
        }

        return arena.withUnsafeBufferPointer {
            buffer in

            var pointers:
                [UnsafePointer<CChar>?] = []
            pointers.reserveCapacity(
                offsets.count
            )

            for offset in offsets {
                guard
                    let offset,
                    let base = buffer.baseAddress
                else {
                    pointers.append(nil)
                    continue
                }

                pointers.append(
                    base + offset
                )
            }

            return pointers
                .withUnsafeBufferPointer {
                    pointers in

                    types.withUnsafeBufferPointer {
                        types in

                        body(
                            pointers,
                            types
                        )
                    }
                }
        }
    }
}

internal struct PostgresTransaction:
    DatabaseTransaction
{
    let connection: PostgresConnection

    func execute(
        _ query: DatabaseQuery
    ) async throws -> DatabaseQueryResult {
        try await connection.execute(query)
    }

    func withTransaction<T: Sendable>(
        _ body: @escaping @Sendable (
            any DatabaseTransaction
        ) async throws -> T
    ) async throws -> T {
        throw DatabaseError(
            kind: .transaction,
            message:
                "Nested Postgres transactions are not supported"
        )
    }
}
