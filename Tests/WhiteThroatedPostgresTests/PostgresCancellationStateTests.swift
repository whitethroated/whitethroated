import CPostgres
import Dispatch
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import WhiteThroatedPostgres

final class PostgresCancellationStateTests: XCTestCase {
    /// `SOCK_STREAM` experiments as an `Int32` argument on Darwin and as a
    /// C enum (`__socket_type`) on Linux; normalize once.
    private static let streamType: Int32 = {
        #if canImport(Darwin)
        return Int32(SOCK_STREAM)
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }()

    // The C socket functions are qualified through the platform's libc
    // module because an unqualified call can resolve to an instance
    // method with the same name on some toolchains.
    private static func hostSocket() -> Int32 {
        #if canImport(Darwin)
        return Darwin.socket(AF_INET, streamType, 0)
        #else
        return Glibc.socket(AF_INET, streamType, 0)
        #endif
    }

    private static func hostBind(
        _ descriptor: Int32,
        _ address: UnsafePointer<sockaddr>,
        _ length: socklen_t
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(descriptor, address, length)
        #else
        return Glibc.bind(descriptor, address, length)
        #endif
    }

    private static func hostListen(
        _ descriptor: Int32,
        _ backlog: Int32
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(descriptor, backlog)
        #else
        return Glibc.listen(descriptor, backlog)
        #endif
    }

    private static func hostName(
        _ descriptor: Int32,
        _ address: UnsafeMutablePointer<sockaddr>,
        _ length: UnsafeMutablePointer<socklen_t>
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.getsockname(
            descriptor,
            address,
            length
        )
        #else
        return Glibc.getsockname(
            descriptor,
            address,
            length
        )
        #endif
    }

    private static func hostAccept(
        _ descriptor: Int32
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.accept(
            descriptor,
            nil,
            nil
        )
        #else
        return Glibc.accept(
            descriptor,
            nil,
            nil
        )
        #endif
    }

    private static func hostClose(
        _ descriptor: Int32
    ) {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
    }

    /// A local listening socket with no accept response keeps `PQgetCancel`
    /// happy (the connection object owns an open socket after
    /// `PQconnectStart`) while a real `PQcancel` attempt sends soundly into
    /// the kernel backlog without needing a server.
    private static let listenerPort: UInt16 = {
        let descriptor = hostSocket()
        precondition(
            descriptor >= 0,
            "could not allocate a listener socket"
        )

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        #if canImport(Darwin)
        address.sin_len = UInt8(
            MemoryLayout<sockaddr_in>.size
        )
        #endif
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
                    hostBind(
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

        let listenResult = hostListen(descriptor, 4)
        precondition(
            listenResult == 0,
            "could not listen on the listener socket"
        )

        // A real postmaster accepts the cancel connection, reads the
        // CancelRequest, and closes it. Linux libpq 16 `PQcancel` waits
        // for at least the close: against a silent listener, one of these
        // sends never returns, and because sends run on the serial cancel
        // queue, every later real cancellation would starve behind it.
        // Pump accepted connections closed so each send drains.
        DispatchQueue.global().async {
            while true {
                let accepted = hostAccept(descriptor)

                if accepted >= 0 {
                    hostClose(accepted)
                }
            }
        }

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
                        hostName(
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
