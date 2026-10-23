#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

import Dispatch
import Foundation
import WhiteThroated
import WhiteThroatedLifecycle

private enum DeploymentConfigurationError:
    Error
{
    case invalidPort(String)
    case invalidDrainTimeout(String)
}

private func parsePort(
    _ rawValue: String
) throws -> Int {
    guard
        let port = Int(rawValue),
        (1...65_535).contains(port)
    else {
        throw DeploymentConfigurationError
            .invalidPort(rawValue)
    }

    return port
}

private func parseDrainTimeoutNanoseconds(
    _ rawValue: String
) throws -> UInt64 {
    guard
        let seconds = UInt64(rawValue),
        seconds <= 3_600
    else {
        throw DeploymentConfigurationError
            .invalidDrainTimeout(rawValue)
    }

    return seconds * 1_000_000_000
}

let environment = ProcessInfo.processInfo.environment
let host =
    environment["WHITETHROATED_HOST"]
    ?? "0.0.0.0"
let port = try parsePort(
    environment["WHITETHROATED_PORT"]
        ?? "3000"
)
let drainTimeoutNanoseconds =
    try parseDrainTimeoutNanoseconds(
        environment[
            "WHITETHROATED_DRAIN_TIMEOUT_SECONDS"
        ] ?? "30"
    )

let lifecycle = LifecycleController()
let app = Application()

app.use(
    lifecycle: lifecycle,
    readinessPath: "/ready"
)

app.get(
    "/health",
    response: .text("ok")
)

app.get(
    "/",
    response: .text(
        "Hello from WhiteThroated"
    )
)

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let signalQueue = DispatchQueue(
    label:
        "whitethroated.deployment.signals"
)

let terminationSignal =
    DispatchSource.makeSignalSource(
        signal: SIGTERM,
        queue: signalQueue
    )
let interruptSignal =
    DispatchSource.makeSignalSource(
        signal: SIGINT,
        queue: signalQueue
    )

let shutdown:
    @Sendable () -> Void =
{
    Task {
        try? await lifecycle.shutdown(
            application: app,
            drainTimeoutNanoseconds:
                drainTimeoutNanoseconds
        )
    }
}

terminationSignal.setEventHandler(
    handler: shutdown
)
interruptSignal.setEventHandler(
    handler: shutdown
)

let channel = try app.listen(
    host: host,
    port: port
)

terminationSignal.resume()
interruptSignal.resume()

try channel.closeFuture.wait()

terminationSignal.cancel()
interruptSignal.cancel()
