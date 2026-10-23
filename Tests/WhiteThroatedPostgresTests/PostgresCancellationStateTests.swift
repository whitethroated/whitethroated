import CPostgres
import XCTest

@testable import WhiteThroatedPostgres

final class PostgresCancellationStateTests: XCTestCase {
    /// A local listening socket with no accept response keeps `PQgetCancel`
    /// happy (the connection object owns an open socket after
    /// `PQconnectStart`) while a real `PQcancel` attempt sends soundly into
    /// the kernel backlog without needing a server.
    private static let listenerPort: UInt16 = {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        precondition(
            descriptor >= 0,
            "could not allocate a listener socket"
        )

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(
            MemoryLayout<sockaddr_in>.size
        )
        address.sin_port = 0
        address.sin_addr = in_addr(
            s_addr: INADDR_ANY
        )

        let bindResult =
            withUnsafePointer(
                to: &address
            ) { pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { reboundPointer in
                    Darwin.bind(
                        descriptor,
                        reboundPointer,
                        socklen_t(
                            MemoryLayout<
                                sockaddr_in
                            >.size
                        )
                    )
                }
            }
        precondition(
            bindResult == 0,
            "could not bind the listener socket"
        )

        let listenResult = Darwin.listen(descriptor, 4)
        precondition(
            listenResult == 0,
            "could not listen on the listener socket"
        )

        var bound = sockaddr_in()
        var length = socklen_t(
            MemoryLayout<sockaddr_in>.size
        )
        let nameResult =
            withUnsafeMutablePointer(
                to: &bound
            ) { pointer in
                withUnsafeMutablePointer(
                    to: &length
                ) { lengthPointer in
                    pointer.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) { reboundPointer in
                        Darwin.getsockname(
                            descriptor,
                            reboundPointer,
                            lengthPointer
                        )
                    }
                }
            }
        precondition(
            nameResult == 0,
            "could not read the listener port"
        )

        return UInt16(
            bigEndian: bound.sin_port
        )
    }()

    /// Builds a libpq connection object that owns an open socket without a
    /// PostgreSQL server behind it, so `PQgetCancel` yields a usable
    /// `PGcancel` handle.
    private func makeConnectableHandle() -> OpaquePointer! {
        let connectionInfo =
            "host=127.0.0.1 port=\(Self.listenerPort)"

        let handle =
            connectionInfo.withCString(
                PQconnectStart
            )

        precondition(
            handle != nil,
            "libpq could not allocate a connection object"
        )

        return handle
    }

    func testRequestBeforeInstallStillSendsAndDrains() {
        // A cancel request that arrives before the connection queue installs
        // the cancel handle must trigger the deferred send at install time,
        // and the free-ladder must stay balanced: finish() defers the free
        // because one send is in flight, and the drained send releases it.
        let connection = makeConnectableHandle()
        defer {
            PQfinish(connection)
        }

        guard
            let cancel = PQgetCancel(connection)
        else {
            XCTFail("PQgetCancel refused a valid connection handle")
            return
        }

        let state = PostgresCancellationState()

        state.requestCancel()
        XCTAssertTrue(state.isCancelRequested)

        state.install(cancel)
        state.finish()
    }

    func testFinishBeforeLateRequestIsIgnoredEntirely() {
        // Once finish() has freed the handle, a late cancel request is a
        // no-op: nothing sends, and the request flag stays untouched — the
        // queued work being cancelled no longer exists.
        let connection = makeConnectableHandle()
        defer {
            PQfinish(connection)
        }

        guard
            let cancel = PQgetCancel(connection)
        else {
            XCTFail("PQgetCancel refused a valid connection handle")
            return
        }

        let state = PostgresCancellationState()

        state.install(cancel)
        state.finish()
        state.requestCancel()

        XCTAssertFalse(state.isCancelRequested)
    }

    func testInterleavedRequestsAndFinishStayBalanced() {
        // Hammers the ownership ladder with many orderings: install, request,
        // and finish interleaved. Every iteration must end balanced —
        // no double free, no missed free, no crash.
        for iteration in 0..<64 {
            let connection = makeConnectableHandle()
            let state = PostgresCancellationState()

            guard
                let cancel = PQgetCancel(connection)
            else {
                PQfinish(connection)
                XCTFail("PQgetCancel refused a valid connection handle")
                return
            }

            state.install(cancel)

            if iteration % 2 == 0 {
                state.requestCancel()
                state.finish()
            } else {
                state.finish()

                if iteration % 4 == 3 {
                    state.requestCancel()
                }
            }

            PQfinish(connection)
        }
    }
}
