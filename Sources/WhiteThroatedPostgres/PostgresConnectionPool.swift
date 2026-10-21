import WhiteThroatedDatabase

internal actor PostgresConnectionPool {
    private struct Waiter {
        let id: UInt64
        let continuation:
            CheckedContinuation<
                PostgresConnection,
                Error
            >
    }

    private let configuration:
        PostgresConfiguration
    private var available:
        [PostgresConnection] = []
    private var waiters:
        [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private var total = 0
    private var isShuttingDown = false
    private var isShutdownComplete = false
    private var shutdownWaiters:
        [CheckedContinuation<Void, Never>] = []

    init(
        configuration: PostgresConfiguration
    ) {
        self.configuration = configuration
    }

    var waiterCount: Int {
        waiters.count
    }

    func validate() async throws {
        let connection =
            try await lease()

        await release(connection)
    }

    func lease() async throws -> PostgresConnection {
        if isShutdownComplete || isShuttingDown {
            throw PostgresErrorMapper.shutdown()
        }

        if let connection = available.popLast() {
            return connection
        }

        if total < configuration.poolSize {
            total += 1

            let connection: PostgresConnection

            do {
                connection =
                    try await PostgresConnection
                        .connect(
                            configuration:
                                configuration
                        )
            } catch {
                total -= 1
                failWaiters(error)
                completeShutdownIfNeeded()
                throw error
            }

            if isShuttingDown {
                await connection.close()
                total -= 1
                completeShutdownIfNeeded()

                throw PostgresErrorMapper
                    .shutdown()
            }

            return connection
        }

        let waiterID =
            nextWaiterID
        nextWaiterID += 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in

                waiters.append(
                    Waiter(
                        id: waiterID,
                        continuation: continuation
                    )
                )

                if Task.isCancelled,
                   waiters.last?.id == waiterID
                {
                    let waiter =
                        waiters.removeLast()
                    waiter.continuation.resume(
                        throwing: CancellationError()
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID
                )
            }
        }
    }

    func release(
        _ connection: PostgresConnection
    ) async {
        if isShuttingDown {
            await connection.close()
            total -= 1
            completeShutdownIfNeeded()
            return
        }

        if !connection.isBroken {
            await connection.prepareForRelease()
        }

        if isShuttingDown {
            await connection.close()
            total -= 1
            completeShutdownIfNeeded()
            return
        }

        if connection.isBroken {
            await connection.close()
            total -= 1

            if !waiters.isEmpty {
                await replaceWaiter()
            } else {
                completeShutdownIfNeeded()
            }

            return
        }

        if !waiters.isEmpty {
            let waiter =
                waiters.removeFirst()
            waiter.continuation.resume(
                returning: connection
            )
            return
        }

        available.append(
            connection
        )
    }

    func shutdown() async {
        if isShutdownComplete {
            return
        }

        if isShuttingDown {
            if total == 0 {
                isShutdownComplete = true
                return
            }

            await withCheckedContinuation {
                shutdownWaiters.append($0)
            }
            return
        }

        isShuttingDown = true

        let pendingWaiters =
            waiters
        waiters.removeAll()
        let error =
            PostgresErrorMapper.shutdown()

        for waiter in pendingWaiters {
            waiter.continuation.resume(
                throwing: error
            )
        }

        let connections =
            available
        available.removeAll()

        for connection in connections {
            await connection.close()
            total -= 1
        }

        if total == 0 {
            isShutdownComplete = true
            resumeShutdownWaiters()
            return
        }

        await withCheckedContinuation {
            shutdownWaiters.append($0)
        }
    }

    private func replaceWaiter() async {
        guard
            !isShuttingDown,
            !waiters.isEmpty
        else {
            completeShutdownIfNeeded()
            return
        }

        let waiter =
            waiters.removeFirst()
        total += 1

        do {
            let connection =
                try await PostgresConnection
                    .connect(
                        configuration:
                            configuration
                    )

            if isShuttingDown {
                await connection.close()
                total -= 1
                waiter.continuation.resume(
                    throwing:
                        PostgresErrorMapper
                            .shutdown()
                )
                completeShutdownIfNeeded()
                return
            }

            waiter.continuation.resume(
                returning: connection
            )
        } catch {
            total -= 1
            waiter.continuation.resume(
                throwing: error
            )

            // A failed replacement usually means the server is unavailable.
            // Fail queued leases instead of leaving them suspended until a
            // future release that may never happen.
            let remaining =
                waiters
            waiters.removeAll()

            for waiter in remaining {
                waiter.continuation.resume(
                    throwing: error
                )
            }

            completeShutdownIfNeeded()
        }
    }

    private func cancelWaiter(
        _ id: UInt64
    ) {
        guard
            let index = waiters.firstIndex(
                where: {
                    $0.id == id
                }
            )
        else {
            return
        }

        let waiter =
            waiters.remove(at: index)
        waiter.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func completeShutdownIfNeeded() {
        guard
            isShuttingDown,
            total == 0,
            !isShutdownComplete
        else {
            return
        }

        isShutdownComplete = true
        resumeShutdownWaiters()
    }

    private func failWaiters(
        _ error: Error
    ) {
        let pending =
            waiters
        waiters.removeAll()

        for waiter in pending {
            waiter.continuation.resume(
                throwing: error
            )
        }
    }

    private func resumeShutdownWaiters() {
        let waiters =
            shutdownWaiters
        shutdownWaiters.removeAll()

        for waiter in waiters {
            waiter.resume()
        }
    }
}
