import CPostgres
import Dispatch
import NIOConcurrencyHelpers

/// Coordinates one in-flight libpq query with Swift task cancellation.
///
/// `@unchecked Sendable` is justified by `state`: cancel-request state, the
/// `PQcancel` handle, and the drain counter for in-flight send requests are
/// all protected by one lock, and the handle is freed exactly once — from
/// ``finish()`` when no send is in flight, otherwise by the last in-flight
/// send once sending has drained.
final class PostgresCancellationState:
    @unchecked Sendable
{
    /// `PQcancel` performs blocking socket work. It must never run on a
    /// request thread (an observing event loop) or under the state lock,
    /// and it must not queue behind the connection queue, whose
    /// head-of-line blocking query is exactly the work the cancel is meant
    /// to interrupt. Send requests therefore run on this dedicated queue.
    private static let cancelQueue =
        DispatchQueue(
            label: "whitethroated.postgres.cancel"
        )

    private struct State {
        var cancel: OpaquePointer?
        var cancelRequested = false
        var finished = false
        var inFlightSends = 0
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
        var pendingHandle: OpaquePointer?

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
                state.inFlightSends += 1
                pendingHandle = cancel
            }
        }

        if let pendingHandle {
            dispatchSend(pendingHandle)
        }
    }

    func requestCancel() {
        var pendingHandle: OpaquePointer?

        state.withLockedValue {
            state in

            guard !state.finished else {
                return
            }

            state.cancelRequested = true

            if let cancel = state.cancel {
                state.inFlightSends += 1
                pendingHandle = cancel
            }
        }

        if let pendingHandle {
            dispatchSend(pendingHandle)
        }
    }

    func finish() {
        var released: OpaquePointer?

        state.withLockedValue {
            state in

            guard !state.finished else {
                return
            }

            state.finished = true

            if state.inFlightSends == 0,
               let cancel = state.cancel
            {
                released = cancel
                state.cancel = nil
            }
            // Otherwise the last in-flight send frees the handle once
            // every have-been-sent request has drained.
        }

        if let released {
            PQfreeCancel(released)
        }
    }

    /// Runs one reserved send on the cancel queue. The handle stays valid:
    /// it can only be freed once every reservation has drained, and this
    /// drain is what releases the final handle when the query already
    /// finished while the send was in flight.
    private func dispatchSend(
        _ cancel: OpaquePointer
    ) {
        Self.cancelQueue.async {
            [self] in

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

            var released: OpaquePointer?

            self.state.withLockedValue {
                state in

                state.inFlightSends -= 1

                if state.finished,
                   state.inFlightSends == 0,
                   let pending = state.cancel
                {
                    released = pending
                    state.cancel = nil
                }
            }

            if let released {
                PQfreeCancel(released)
            }
        }
    }
}
