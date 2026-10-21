import Dispatch
import NIOConcurrencyHelpers
import WhiteThroated

public enum LifecyclePhase:
    String,
    Sendable,
    Equatable
{
    case accepting
    case draining
    case stopped
}

public struct LifecycleSnapshot:
    Sendable,
    Equatable
{
    public let phase: LifecyclePhase
    public let activeRequests: Int

    public var isReady: Bool {
        phase == .accepting
    }

    public init(
        phase: LifecyclePhase,
        activeRequests: Int
    ) {
        self.phase = phase
        self.activeRequests =
            activeRequests
    }
}

public final class LifecycleController:
    @unchecked Sendable
{
    public typealias Cleanup =
        @Sendable () throws -> Void
    public typealias Clock =
        @Sendable () -> UInt64

    private struct State: Sendable {
        var phase:
            LifecyclePhase = .accepting
        var activeRequests = 0
        var cleanups: [Cleanup] = []
    }

    private let state =
        NIOLockedValueBox(State())
    private let clock: Clock

    public init(
        clock: @escaping Clock = {
            DispatchTime.now()
                .uptimeNanoseconds
        }
    ) {
        self.clock = clock
    }

    public func registerCleanup(
        _ cleanup: @escaping Cleanup
    ) {
        state.withLockedValue {
            state in

            precondition(
                state.phase == .accepting,
                "Lifecycle cleanup must be registered before draining starts"
            )

            state.cleanups.append(
                cleanup
            )
        }
    }

    public func middleware() -> FastMiddleware {
        { request, _, next in
            guard self.beginRequest() else {
                return .response(
                    Response.text(
                        "Service Unavailable",
                        status:
                            .serviceUnavailable
                    )
                )
            }

            let result = next(request)
            return self.observe(result)
        }
    }

    public func snapshot()
        -> LifecycleSnapshot
    {
        state.withLockedValue {
            LifecycleSnapshot(
                phase: $0.phase,
                activeRequests:
                    $0.activeRequests
            )
        }
    }

    public func beginDrain() {
        state.withLockedValue {
            state in

            if state.phase == .accepting {
                state.phase = .draining
            }
        }
    }

    public func shutdown(
        application: Application,
        drainTimeoutNanoseconds: UInt64 =
            30_000_000_000,
        pollNanoseconds: UInt64 =
            1_000_000
    ) async throws {
        precondition(
            pollNanoseconds > 0,
            "Lifecycle poll interval must be greater than zero"
        )

        beginDrain()

        let start = clock()

        while true {
            if snapshot().activeRequests == 0 {
                break
            }

            let now = clock()
            let elapsed =
                now >= start
                ? now - start
                : 0

            if elapsed >= drainTimeoutNanoseconds {
                break
            }

            let remaining =
                drainTimeoutNanoseconds
                    - elapsed
            let sleep =
                min(
                    pollNanoseconds,
                    remaining
                )

            if sleep == 0 {
                break
            }

            try await Task.sleep(
                nanoseconds: sleep
            )
        }

        let cleanups =
            state.withLockedValue {
                Array(
                    $0.cleanups.reversed()
                )
            }

        var firstError: Error?

        for cleanup in cleanups {
            do {
                try cleanup()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        do {
            try application.shutdown()
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        state.withLockedValue {
            state in
            state.phase = .stopped
        }

        if let firstError {
            throw firstError
        }
    }

    public func readinessResponse()
        -> Response
    {
        let snapshot = snapshot()

        if snapshot.isReady {
            return .text("ready")
        }

        return .text(
            "not ready",
            status: .serviceUnavailable
        )
    }

    private func beginRequest() -> Bool {
        state.withLockedValue {
            state in

            guard
                state.phase == .accepting
            else {
                return false
            }

            state.activeRequests += 1
            return true
        }
    }

    private func observe(
        _ result: MiddlewareResult
    ) -> MiddlewareResult {
        switch result {
        case .response,
             .prepared:
            finishRequest()
            return result

        case .future(let future):
            future.whenComplete { _ in
                self.finishRequest()
            }
            return .future(future)
        }
    }

    private func finishRequest() {
        state.withLockedValue {
            state in

            precondition(
                state.activeRequests > 0,
                "Lifecycle active request count underflow"
            )

            state.activeRequests -= 1
        }
    }
}

public extension Application {
    func use(
        lifecycle:
            LifecycleController,
        readinessPath: String =
            "/ready"
    ) {
        useFast(
            lifecycle.middleware()
        )

        get(readinessPath) { _ in
            lifecycle
                .readinessResponse()
        }
    }
}
