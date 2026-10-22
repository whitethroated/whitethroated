import NIOCore
import NIOWebSocket

public struct WebSocketClose:
    Sendable,
    Equatable
{
    public let code:
        WebSocketErrorCode?
    public let reason: String?

    public init(
        code: WebSocketErrorCode?,
        reason: String?
    ) {
        self.code = code
        self.reason = reason
    }
}

public enum WebSocketConnectionError:
    Error,
    Sendable,
    Equatable
{
    case closing
    case closeReasonTooLong
    case controlPayloadTooLarge
}

public final class WebSocketConnection:
    @unchecked Sendable
{
    public let subprotocol: String?

    private let state:
        WebSocketConnectionState

    internal init(
        channel: Channel,
        closeTimeoutSeconds: Int64,
        subprotocol: String?
    ) {
        self.subprotocol = subprotocol
        self.state =
            WebSocketConnectionState(
                channel: channel,
                closeTimeoutSeconds:
                    closeTimeoutSeconds
            )
    }

    public var eventLoop: EventLoop {
        state.channel.eventLoop
    }

    internal var stateForHandler:
        WebSocketConnectionState
    {
        state
    }

    public var remoteAddress:
        SocketAddress?
    {
        state.channel.remoteAddress
    }

    public func sendText(
        _ text: String
    ) -> EventLoopFuture<Void> {
        var buffer =
            state.channel.allocator
                .buffer(
                    capacity:
                        text.utf8.count
                )
        buffer.writeString(text)

        return state.write(
            WebSocketFrame(
                fin: true,
                opcode: .text,
                data: buffer
            )
        )
    }

    public func sendBinary(
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        state.write(
            WebSocketFrame(
                fin: true,
                opcode: .binary,
                data: buffer
            )
        )
    }

    public func ping(
        _ buffer: ByteBuffer? = nil
    ) -> EventLoopFuture<Void> {
        controlFrame(
            opcode: .ping,
            buffer: buffer
        )
    }

    public func pong(
        _ buffer: ByteBuffer? = nil
    ) -> EventLoopFuture<Void> {
        controlFrame(
            opcode: .pong,
            buffer: buffer
        )
    }

    private func controlFrame(
        opcode: WebSocketOpcode,
        buffer: ByteBuffer?
    ) -> EventLoopFuture<Void> {
        let payload =
            buffer
            ?? state.channel.allocator
                .buffer(capacity: 0)

        guard
            payload.readableBytes <= 125
        else {
            return eventLoop
                .makeFailedFuture(
                    WebSocketConnectionError
                        .controlPayloadTooLarge
                )
        }

        return state.write(
            WebSocketFrame(
                fin: true,
                opcode: opcode,
                data: payload
            )
        )
    }

    public func close(
        code:
            WebSocketErrorCode =
                .normalClosure,
        reason: String? = nil
    ) -> EventLoopFuture<Void> {
        state.close(
            code: code,
            reason: reason
        )
    }
}

internal final class WebSocketConnectionState:
    @unchecked Sendable
{
    let channel: Channel

    private let closeTimeoutSeconds:
        Int64

    private var closeSent = false
    private var closeReceived = false
    private var closeTimer:
        Scheduled<Void>?

    init(
        channel: Channel,
        closeTimeoutSeconds: Int64
    ) {
        self.channel = channel
        self.closeTimeoutSeconds =
            closeTimeoutSeconds
    }

    func write(
        _ frame: WebSocketFrame
    ) -> EventLoopFuture<Void> {
        onEventLoop {
            guard !self.closeSent else {
                return self.channel.eventLoop
                    .makeFailedFuture(
                        WebSocketConnectionError
                            .closing
                    )
            }

            return self.channel
                .writeAndFlush(frame)
        }
    }

    func close(
        code: WebSocketErrorCode,
        reason: String?
    ) -> EventLoopFuture<Void> {
        let reasonBytes =
            reason.map {
                Array($0.utf8)
            }
            ?? []

        guard reasonBytes.count <= 123 else {
            return channel.eventLoop
                .makeFailedFuture(
                    WebSocketConnectionError
                        .closeReasonTooLong
                )
        }

        return onEventLoop {
            self.sendCloseOnEventLoop(
                code: code,
                reasonBytes:
                    reasonBytes
            )
        }
    }

    func receiveClose(
        payload: ByteBuffer
    ) -> EventLoopFuture<Void> {
        onEventLoop {
            self.closeReceived = true
            self.closeTimer?.cancel()
            self.closeTimer = nil

            if self.closeSent {
                return self.channel
                    .close()
            }

            var echo = payload

            if echo.readableBytes == 1 {
                echo.clear()
                echo.write(
                    webSocketErrorCode:
                        .protocolError
                )
            }

            self.closeSent = true

            return self.channel
                .writeAndFlush(
                    WebSocketFrame(
                        fin: true,
                        opcode:
                            .connectionClose,
                        data: echo
                    )
                )
                .flatMap {
                    self.channel.close()
                }
        }
    }

    func closeTransport() {
        if channel.eventLoop.inEventLoop {
            closeTransportOnEventLoop()
        } else {
            channel.eventLoop.execute {
                self.closeTransportOnEventLoop()
            }
        }
    }

    private func sendCloseOnEventLoop(
        code: WebSocketErrorCode,
        reasonBytes: [UInt8]
    ) -> EventLoopFuture<Void> {
        guard !closeSent else {
            return channel.eventLoop
                .makeSucceededVoidFuture()
        }

        closeSent = true

        var payload =
            channel.allocator.buffer(
                capacity:
                    2
                    + reasonBytes.count
            )
        payload.write(
            webSocketErrorCode: code
        )
        payload.writeBytes(
            reasonBytes
        )

        let future =
            channel.writeAndFlush(
                WebSocketFrame(
                    fin: true,
                    opcode:
                        .connectionClose,
                    data: payload
                )
            )

        closeTimer =
            channel.eventLoop
                .scheduleTask(
                    in:
                        .seconds(
                            closeTimeoutSeconds
                        )
                ) {
                    if !self.closeReceived {
                        self.channel.close(
                            promise: nil
                        )
                    }
                }

        future.whenFailure { _ in
            self.channel.close(
                promise: nil
            )
        }

        return future
    }

    private func closeTransportOnEventLoop() {
        closeTimer?.cancel()
        closeTimer = nil
    }

    private func onEventLoop(
        _ operation:
            @escaping @Sendable ()
                -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        if channel.eventLoop.inEventLoop {
            return operation()
        }

        let promise =
            channel.eventLoop
                .makePromise(
                    of: Void.self
                )

        channel.eventLoop.execute {
            operation()
                .cascade(to: promise)
        }

        return promise.futureResult
    }
}
