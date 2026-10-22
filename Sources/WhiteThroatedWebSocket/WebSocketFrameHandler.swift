import Foundation
import NIOCore
import NIOWebSocket

internal final class WebSocketFrameHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn =
        WebSocketFrame

    private enum FragmentKind {
        case text
        case binary
    }

    private let connection:
        WebSocketConnection
    private let route:
        WebSocketRoute
    private let maxMessageBytes: Int
    private let eventSink:
        WebSocketRouter.EventSink?

    private var fragmentedKind:
        FragmentKind?
    private var fragmentedBuffer:
        ByteBuffer?
    private var closeNotificationSent =
        false
    private var lastClose:
        WebSocketClose?

    init(
        connection:
            WebSocketConnection,
        route: WebSocketRoute,
        maxMessageBytes: Int,
        eventSink:
            WebSocketRouter.EventSink?
    ) {
        self.connection = connection
        self.route = route
        self.maxMessageBytes =
            maxMessageBytes
        self.eventSink = eventSink
    }

    func channelRead(
        context:
            ChannelHandlerContext,
        data: NIOAny
    ) {
        let frame =
            unwrapInboundIn(data)

        switch frame.opcode {
        case .text:
            receiveDataFrame(
                kind: .text,
                frame: frame,
                context: context
            )

        case .binary:
            receiveDataFrame(
                kind: .binary,
                frame: frame,
                context: context
            )

        case .continuation:
            receiveContinuation(
                frame,
                context: context
            )

        case .ping:
            let future =
                connection.pong(
                    frame.unmaskedData
                )
            future.whenFailure {
                _ in
                context.close(
                    promise: nil
                )
            }

        case .pong:
            route.handlers
                .onPong?(
                    connection,
                    frame.unmaskedData
                )

        case .connectionClose:
            receiveClose(
                frame,
                context: context
            )

        default:
            protocolViolation(
                context: context
            )
        }

        requestNextReadIfWritable(
            context
        )
    }

    func channelWritabilityChanged(
        context:
            ChannelHandlerContext
    ) {
        requestNextReadIfWritable(
            context
        )

        context
            .fireChannelWritabilityChanged()
    }

    func channelInactive(
        context:
            ChannelHandlerContext
    ) {
        connection.stateForHandler
            .closeTransport()

        notifyClose(
            lastClose
            ?? WebSocketClose(
                code: nil,
                reason: nil
            )
        )

        context.fireChannelInactive()
    }

    func errorCaught(
        context:
            ChannelHandlerContext,
        error: Error
    ) {
        context.close(
            promise: nil
        )
    }

    private func receiveDataFrame(
        kind: FragmentKind,
        frame: WebSocketFrame,
        context:
            ChannelHandlerContext
    ) {
        guard fragmentedKind == nil else {
            protocolViolation(
                context: context
            )
            return
        }

        let payload =
            frame.unmaskedData

        guard
            payload.readableBytes
                <= maxMessageBytes
        else {
            messageTooLarge(
                context: context
            )
            return
        }

        if frame.fin {
            deliver(
                kind: kind,
                payload: payload,
                context: context
            )
            return
        }

        fragmentedKind = kind

        var aggregate =
            context.channel.allocator
                .buffer(
                    capacity:
                        payload
                            .readableBytes
                )
        var copy = payload
        aggregate.writeBuffer(
            &copy
        )
        fragmentedBuffer =
            aggregate
    }

    private func receiveContinuation(
        _ frame: WebSocketFrame,
        context:
            ChannelHandlerContext
    ) {
        guard
            let kind = fragmentedKind,
            var aggregate =
                fragmentedBuffer
        else {
            protocolViolation(
                context: context
            )
            return
        }

        let payload =
            frame.unmaskedData

        guard
            aggregate.readableBytes
                + payload.readableBytes
                <= maxMessageBytes
        else {
            clearFragment()
            messageTooLarge(
                context: context
            )
            return
        }

        var copy = payload
        aggregate.writeBuffer(
            &copy
        )

        if frame.fin {
            clearFragment()
            deliver(
                kind: kind,
                payload: aggregate,
                context: context
            )
        } else {
            fragmentedBuffer =
                aggregate
        }
    }

    private func deliver(
        kind: FragmentKind,
        payload: ByteBuffer,
        context:
            ChannelHandlerContext
    ) {
        switch kind {
        case .text:
            let bytes =
                Array(
                    payload
                        .readableBytesView
                )

            guard
                let value =
                    String(
                        bytes: bytes,
                        encoding: .utf8
                    )
            else {
                invalidText(
                    context: context
                )
                return
            }

            eventSink?(
                .message(
                    route: route.path,
                    kind: .text,
                    bytes:
                        payload
                            .readableBytes
                )
            )

            route.handlers
                .onText?(
                    connection,
                    value
                )

        case .binary:
            eventSink?(
                .message(
                    route: route.path,
                    kind: .binary,
                    bytes:
                        payload
                            .readableBytes
                )
            )

            route.handlers
                .onBinary?(
                    connection,
                    payload
                )
        }
    }

    private func receiveClose(
        _ frame: WebSocketFrame,
        context:
            ChannelHandlerContext
    ) {
        let payload =
            frame.unmaskedData

        guard
            let close =
                parseClose(payload)
        else {
            protocolViolation(
                context: context
            )
            return
        }

        lastClose = close
        notifyClose(close)

        connection.stateForHandler
            .receiveClose(
                payload: payload
            )
            .whenFailure {
                _ in

                context.close(
                    promise: nil
                )
            }
    }

    private func parseClose(
        _ payload: ByteBuffer
    ) -> WebSocketClose? {
        let count =
            payload.readableBytes

        if count == 0 {
            return WebSocketClose(
                code: nil,
                reason: nil
            )
        }

        guard count >= 2 else {
            return nil
        }

        var copy = payload

        guard
            let code =
                copy
                    .readWebSocketErrorCode()
        else {
            return nil
        }

        let reasonBytes =
            Array(
                copy.readableBytesView
            )

        let reason: String?

        if reasonBytes.isEmpty {
            reason = nil
        } else {
            guard
                let decoded =
                    String(
                        bytes:
                            reasonBytes,
                        encoding: .utf8
                    )
            else {
                return nil
            }

            reason = decoded
        }

        return WebSocketClose(
            code: code,
            reason: reason
        )
    }

    private func protocolViolation(
        context:
            ChannelHandlerContext
    ) {
        clearFragment()

        connection.close(
            code: .protocolError,
            reason: "Protocol error"
        )
        .whenFailure {
            _ in
            context.close(
                promise: nil
            )
        }
    }

    private func invalidText(
        context:
            ChannelHandlerContext
    ) {
        connection.close(
            code:
                .dataInconsistentWithMessage,
            reason:
                "Invalid UTF-8 text"
        )
        .whenFailure {
            _ in
            context.close(
                promise: nil
            )
        }
    }

    private func messageTooLarge(
        context:
            ChannelHandlerContext
    ) {
        connection.close(
            code: .messageTooLarge,
            reason: "Message too large"
        )
        .whenFailure {
            _ in
            context.close(
                promise: nil
            )
        }
    }

    private func clearFragment() {
        fragmentedKind = nil
        fragmentedBuffer = nil
    }

    private func requestNextReadIfWritable(
        _ context:
            ChannelHandlerContext
    ) {
        if
            context.channel.isActive,
            context.channel.isWritable
        {
            context.read()
        }
    }

    private func notifyClose(
        _ close: WebSocketClose
    ) {
        guard
            !closeNotificationSent
        else {
            return
        }

        closeNotificationSent = true

        eventSink?(
            .closed(
                route: route.path,
                code:
                    close.code.map {
                        Int(
                            UInt16(
                                webSocketErrorCode:
                                    $0
                            )
                        )
                    }
            )
        )

        route.handlers
            .onClose?(
                connection,
                close
            )
    }
}
