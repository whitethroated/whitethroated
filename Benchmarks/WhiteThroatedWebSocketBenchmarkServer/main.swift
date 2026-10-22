import Foundation
import WhiteThroated
import WhiteThroatedWebSocket

let environment =
    ProcessInfo.processInfo.environment

let host =
    environment[
        "WHITETHROATED_HOST"
    ] ?? "127.0.0.1"
let port =
    Int(
        environment[
            "WHITETHROATED_PORT"
        ] ?? "3000"
    )
    ?? 3000
let threads =
    Int(
        environment[
            "WHITETHROATED_THREADS"
        ] ?? ""
    )

let app = Application(
    configuration:
        ServerConfiguration(
            eventLoopThreads: threads
        )
)

let benchmarkDate =
    "Thu, 01 Jan 1970 00:00:00 GMT"
let hello =
    PreparedResponse
        .text("Hello, World!")
        .header(
            "date",
            benchmarkDate
        )

app.get(
    "/prepared",
    response: hello
)

if
    environment[
        "WHITETHROATED_WEBSOCKET_INSTALL"
    ] == "1"
{
    let maxFrameBytes =
        Int(
            environment[
                "WHITETHROATED_WEBSOCKET_MAX_FRAME_BYTES"
            ] ?? "16384"
        )
        ?? 16_384
    let maxMessageBytes =
        Int(
            environment[
                "WHITETHROATED_WEBSOCKET_MAX_MESSAGE_BYTES"
            ] ?? "1048576"
        )
        ?? 1_048_576

    var router =
        WebSocketRouter(
            configuration:
                WebSocketConfiguration(
                    maxFrameBytes:
                        maxFrameBytes,
                    maxMessageBytes:
                        maxMessageBytes
                )
        )

    try router.on(
        "/websocket",
        handlers:
            WebSocketHandlers(
                onText: {
                    connection,
                    text in

                    _ = connection
                        .sendText(text)
                },
                onBinary: {
                    connection,
                    bytes in

                    _ = connection
                        .sendBinary(bytes)
                }
            )
    )

    app.use(
        webSockets: router
    )
}

try app.run(
    host: host,
    port: port
)
