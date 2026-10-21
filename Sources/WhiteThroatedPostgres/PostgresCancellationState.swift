import CPostgres
import NIOConcurrencyHelpers

/// Coordinates one in-flight libpq query with Swift task cancellation.
///
/// `@unchecked Sendable` is justified by `state`: cancel-request state and the
/// PQcancel handle are protected by one lock, and the handle is freed exactly
/// once.
final class PostgresCancellationState:
    @unchecked Sendable
{
    private struct State {
        var cancel: OpaquePointer?
        var cancelRequested = false
        var finished = false
    }

    private let state =
        NIOLockedValueBox(State())

    var isCancelRequested: Bool {
        state.withLockedValue {
            $0.cancelRequested
        }
    }

    func install(
        _ cancel: OpaquePointer?
    ) {
        state.withLockedValue {
            state in

            guard !state.finished else {
                if let cancel {
                    PQfreeCancel(cancel)
                }
                return
            }

            state.cancel = cancel

            if state.cancelRequested,
               let cancel
            {
                self.sendCancel(cancel)
            }
        }
    }

    func requestCancel() {
        state.withLockedValue {
            state in

            guard !state.finished else {
                return
            }

            state.cancelRequested = true

            if let cancel = state.cancel {
                self.sendCancel(cancel)
            }
        }
    }

    func finish() {
        state.withLockedValue {
            state in

            guard !state.finished else {
                return
            }

            state.finished = true

            if let cancel = state.cancel {
                PQfreeCancel(cancel)
                state.cancel = nil
            }
        }
    }

    private func sendCancel(
        _ cancel: OpaquePointer
    ) {
        var buffer =
            [CChar](
                repeating: 0,
                count: 256
            )

        _ = PQcancel(
            cancel,
            &buffer,
            Int32(buffer.count)
        )
    }
}
