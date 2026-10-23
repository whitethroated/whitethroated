import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket
import XCTest
@testable import WhiteThroated
import WhiteThroatedAuth
@testable import WhiteThroatedWebSocket

final class WebSocketTests:
    XCTestCase
{
    private final class Box<Value>:
        @unchecked Sendable
    {
        var values: [Value] = []

        func append(_ value: Value) {
            values.append(value)
        }
    }

    /// User-defined acceptance failure used to prove that failing
    /// acceptance futures downgrade into plain refusals.
    private struct AcceptanceBoom: Error {}

    func testRouterInstallsUpgradeAndNegotiatesSubprotocol() throws {
        var router =
            WebSocketRouter()
        try router.on(
            "/chat",
            configuration:
                WebSocketRouteConfiguration(
                    subprotocols: [
                        "chat.v2",
                        "chat.v1",
                    ],
                    requireSubprotocol:
                        true
                ),
            handlers:
                WebSocketHandlers()
        )

        let app = Application()
        app.use(webSockets: router)

        let upgrade =
            try XCTUnwrap(
                app.httpServerUpgrade
            )
        XCTAssertEqual(
            upgrade.upgraders.count,
            1
        )

        let channel =
            EmbeddedChannel()
        let head =
            upgradeHead(
                path: "/chat?token=ignored",
                subprotocol:
                    "chat.v1, chat.v2"
            )
        let responseHeaders =
            try upgrade.upgraders[0]
                .buildUpgradeResponse(
                    channel: channel,
                    upgradeRequest: head,
                    initialResponseHeaders:
                        HTTPHeaders()
                )
                .wait()

        XCTAssertEqual(
            responseHeaders.first(
                name:
                    "sec-websocket-protocol"
            ),
            "chat.v2"
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testHandshakeComposesWithAuthenticatorWithoutModuleDependency() throws {
        let authenticator =
            Authenticator.bearer {
                token,
                _ in

                token == "secret"
                ? AuthPrincipal(id: "u1")
                : nil
            }

        var router =
            WebSocketRouter()
        try router.on(
            "/secure",
            accept: {
                request in

                authenticator
                    .authenticate(
                        request
                    )
                    != nil
            },
            handlers:
                WebSocketHandlers()
        )

        let app = Application()
        app.use(webSockets: router)
        let upgrade =
            try XCTUnwrap(
                app.httpServerUpgrade
            )
        let channel =
            EmbeddedChannel()

        var accepted =
            upgradeHead(
                path: "/secure"
            )
        accepted.headers.add(
            name: "authorization",
            value: "Bearer secret"
        )

        XCTAssertNoThrow(
            try upgrade.upgraders[0]
                .buildUpgradeResponse(
                    channel: channel,
                    upgradeRequest:
                        accepted,
                    initialResponseHeaders:
                        HTTPHeaders()
                )
                .wait()
        )

        var rejected =
            upgradeHead(
                path: "/secure"
            )
        rejected.headers.add(
            name: "authorization",
            value: "Bearer wrong"
        )

        XCTAssertThrowsError(
            try upgrade.upgraders[0]
                .buildUpgradeResponse(
                    channel: channel,
                    upgradeRequest:
                        rejected,
                    initialResponseHeaders:
                        HTTPHeaders()
                )
                .wait()
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testRouterInstallsUpgradeErrorFilter() throws {
        var router =
            WebSocketRouter()
        try router.on(
            "/chat",
            handlers:
                WebSocketHandlers()
        )

        let app = Application()
        app.use(webSockets: router)

        let filter =
            try XCTUnwrap(
                app.upgradeErrorFilter
            )

        // Both NIO downgrade error shapes must be downgraded so
        // the re-delivered request receives a normal HTTP
        // response rather than a bare connection close.
        XCTAssertTrue(
            filter(
                NIOWebSocketUpgradeError
                    .unsupportedWebSocketTarget
            )
        )
        XCTAssertTrue(
            filter(
                NIOWebSocketUpgradeError
                    .invalidUpgradeHeader
            )
        )

        // Everything else — including WebSocket frame-level
        // protocol errors that arrive after the upgrade — is not
        // an upgrade-stage error and must still tear the
        // connection down.
        XCTAssertFalse(
            filter(
                WebSocketConnectionError
                    .closing
            )
        )
        XCTAssertFalse(
            filter(
                AcceptanceBoom()
            )
        )
    }

    func testAcceptanceFutureFailureBecomesPlainRefusal() throws {
        var router =
            WebSocketRouter()
        try router.onFuture(
            "/failing",
            accept: {
                request,
                eventLoop in

                eventLoop.makeFailedFuture(
                    AcceptanceBoom()
                )
            },
            handlers:
                WebSocketHandlers()
        )

        let app = Application()
        app.use(webSockets: router)

        let upgrade =
            try XCTUnwrap(
                app.httpServerUpgrade
            )
        let channel =
            EmbeddedChannel()
        let head =
            upgradeHead(
                path: "/failing"
            )

        // An acceptance check that fails with a user-defined
        // error is treated as a refusal: NIO reports its plain
        // unsupported-target error (downgraded by the installed
        // filter) instead of leaking the user error, which would
        // otherwise reach the pipeline unfiltered and close the
        // connection without an HTTP status.
        XCTAssertThrowsError(
            try upgrade.upgraders[0]
                .buildUpgradeResponse(
                    channel: channel,
                    upgradeRequest:
                        head,
                    initialResponseHeaders:
                        HTTPHeaders()
                )
                .wait()
        ) { error in
            XCTAssertEqual(
                error as?
                    NIOWebSocketUpgradeError,
                .unsupportedWebSocketTarget
            )
        }

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testFragmentedTextIsDeliveredOnce() throws {
        let messages =
            Box<String>()
        let (
            channel,
            _
        ) = try makeFrameChannel(
            handlers:
                WebSocketHandlers(
                    onText: {
                        _,
                        value in
                        messages.append(
                            value
                        )
                    }
                )
        )

        var first =
            channel.allocator
                .buffer(capacity: 3)
        first.writeString("hel")

        var second =
            channel.allocator
                .buffer(capacity: 2)
        second.writeString("lo")

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: false,
                opcode: .text,
                data: first
            )
        )
        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode:
                    .continuation,
                data: second
            )
        )

        XCTAssertEqual(
            messages.values,
            ["hello"]
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testPingProducesPongWithSamePayload() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel()

        var payload =
            channel.allocator
                .buffer(capacity: 4)
        payload.writeString("ping")

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode: .ping,
                data: payload
            )
        )

        let pong =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            pong.opcode,
            .pong
        )
        XCTAssertEqual(
            pong.data.getString(
                at:
                    pong.data.readerIndex,
                length:
                    pong.data
                        .readableBytes
            ),
            "ping"
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testOversizedMessageSends1009Close() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel(
            maxMessageBytes: 4
        )

        var payload =
            channel.allocator
                .buffer(capacity: 5)
        payload.writeString("12345")

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode: .binary,
                data: payload
            )
        )

        var close =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            close.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            close.data
                .readWebSocketErrorCode(),
            .messageTooLarge
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testPeerCloseNotifiesExactlyOnceAndEchoesClose() throws {
        let closes =
            Box<WebSocketClose>()
        let (
            channel,
            _
        ) = try makeFrameChannel(
            handlers:
                WebSocketHandlers(
                    onClose: {
                        _,
                        close in
                        closes.append(
                            close
                        )
                    }
                )
        )

        var payload =
            channel.allocator
                .buffer(capacity: 2)
        payload.write(
            webSocketErrorCode:
                .normalClosure
        )

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode:
                    .connectionClose,
                data: payload
            )
        )

        var echoed =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )
        XCTAssertEqual(
            echoed.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            echoed.data
                .readWebSocketErrorCode(),
            .normalClosure
        )

        XCTAssertEqual(
            closes.values.count,
            1
        )
        XCTAssertEqual(
            closes.values.first?.code,
            .normalClosure
        )

        _ = try? channel.finish()

        XCTAssertEqual(
            closes.values.count,
            1
        )
    }

    func testInvalidUTF8TextSends1007Close() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel()

        var payload =
            channel.allocator
                .buffer(capacity: 2)
        payload.writeBytes([
            0xC3,
            0x28,
        ])

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode: .text,
                data: payload
            )
        )

        var close =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            close.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            close.data
                .readWebSocketErrorCode(),
            .dataInconsistentWithMessage
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testUnexpectedContinuationSends1002Close() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel()

        var payload =
            channel.allocator
                .buffer(capacity: 1)
        payload.writeInteger(
            UInt8(1)
        )

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode: .continuation,
                data: payload
            )
        )

        var close =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            close.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            close.data
                .readWebSocketErrorCode(),
            .protocolError
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testUnmaskedClientFrameSends1002Close() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel(
            maskInboundFrames: false
        )

        var payload =
            channel.allocator
                .buffer(capacity: 2)
        payload.writeString("hi")

        // An unmasked frame straight from a client violates
        // RFC 6455 §5.1: the connection must fail with a 1002
        // protocol-error close.
        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode: .text,
                data: payload
            )
        )

        var close =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            close.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            close.data
                .readWebSocketErrorCode(),
            .protocolError
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testReservedBitSends1002Close() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel()

        var payload =
            channel.allocator
                .buffer(capacity: 2)
        payload.writeString("hi")

        // No extensions are negotiated, so a set RSV bit on a
        // masked client frame (the adapter preserves the RSV
        // bits) violates RFC 6455 §5.2/§9.1 and must fail the
        // connection with a 1002 protocol-error close.
        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                rsv1: true,
                opcode: .text,
                data: payload
            )
        )

        var close =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            close.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            close.data
                .readWebSocketErrorCode(),
            .protocolError
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testFragmentedMessageLimitAppliesToAggregate() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel(
            maxMessageBytes: 4
        )

        var first =
            channel.allocator
                .buffer(capacity: 3)
        first.writeString("abc")

        var second =
            channel.allocator
                .buffer(capacity: 2)
        second.writeString("de")

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: false,
                opcode: .binary,
                data: first
            )
        )
        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode: .continuation,
                data: second
            )
        )

        var close =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            close.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            close.data
                .readWebSocketErrorCode(),
            .messageTooLarge
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testForbiddenPeerCloseCodeSendsProtocolError() throws {
        let (
            channel,
            _
        ) = try makeFrameChannel()

        var payload =
            channel.allocator
                .buffer(capacity: 2)
        payload.writeInteger(
            UInt16(1005)
        )

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode:
                    .connectionClose,
                data: payload
            )
        )

        var close =
            try XCTUnwrap(
                channel.readOutbound(
                    as:
                        WebSocketFrame.self
                )
            )

        XCTAssertEqual(
            close.opcode,
            .connectionClose
        )
        XCTAssertEqual(
            close.data
                .readWebSocketErrorCode(),
            .protocolError
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testApplicationCannotSendForbiddenCloseCode() throws {
        let (
            channel,
            connection
        ) = try makeFrameChannel()

        XCTAssertThrowsError(
            try connection.close(
                code: .unknown(1005)
            ).wait()
        ) {
            XCTAssertEqual(
                $0 as?
                    WebSocketConnectionError,
                .invalidCloseCode
            )
        }

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    func testLifecycleSinkUsesBoundedRegisteredRouteLabel() throws {
        let events =
            Box<WebSocketLifecycleEvent>()
        let (
            channel,
            _
        ) = try makeFrameChannel(
            routePath: "/events",
            eventSink: {
                events.append($0)
            }
        )

        var payload =
            channel.allocator
                .buffer(capacity: 3)
        payload.writeString("abc")

        _ = try channel.writeInbound(
            WebSocketFrame(
                fin: true,
                opcode: .binary,
                data: payload
            )
        )

        XCTAssertEqual(
            events.values,
            [
                .message(
                    route: "/events",
                    kind: .binary,
                    bytes: 3
                ),
            ]
        )

        XCTAssertNoThrow(
            try channel.finish()
        )
    }

    private func makeFrameChannel(
        routePath: String = "/socket",
        handlers:
            WebSocketHandlers =
                WebSocketHandlers(),
        maxMessageBytes: Int = 1024,
        eventSink:
            WebSocketRouter.EventSink? =
                nil,
        maskInboundFrames: Bool = true
    ) throws
        -> (
            EmbeddedChannel,
            WebSocketConnection
        )
    {
        let channel =
            EmbeddedChannel()
        let connection =
            WebSocketConnection(
                channel: channel,
                closeTimeoutSeconds: 5,
                subprotocol: nil
            )
        let route =
            WebSocketRoute(
                path: routePath,
                configuration:
                    WebSocketRouteConfiguration(),
                accept: nil,
                handlers: handlers
            )
        let handler =
            WebSocketFrameHandler(
                connection: connection,
                route: route,
                maxMessageBytes:
                    maxMessageBytes,
                eventSink:
                    eventSink
            )

        // The real pipeline's frame decoder forwards frames as
        // they appear on the wire: client frames always carry a
        // masking key and masked payloads. Tests default to the
        // same shape; unmasked in-production-illegal frames use
        // `maskInboundFrames: false` to exercise the handler's
        // own validation.
        if maskInboundFrames {
            try channel.pipeline
                .syncOperations
                .addHandlers(
                    [
                        WireMaskAdapter(),
                        handler,
                    ]
                )
        } else {
            try channel.pipeline
                .syncOperations
                .addHandler(handler)
        }

        return (
            channel,
            connection
        )
    }

    /// Simulates the wire shape for inbound tests: the real frame
    /// decoder forwards client frames with their masking keys and
    /// masked payloads (leaving unmasking to the handler). This
    /// adapter applies the same transformation so tests can inject
    /// frames in plain, unmasked form.
    private final class WireMaskAdapter:
        ChannelInboundHandler,
        @unchecked Sendable
    {
        typealias InboundIn =
            WebSocketFrame
        typealias InboundOut =
            WebSocketFrame

        private let maskingBytes: [UInt8] = [
            0x2a,
            0x4f,
            0x11,
            0x7b,
        ]

        func channelRead(
            context:
                ChannelHandlerContext,
            data: NIOAny
        ) {
            let frame =
                unwrapInboundIn(data)
            var masked =
                frame.data

            for offset
                in 0..<masked
                    .readableBytes
            {
                let index =
                    masked.readerIndex
                        + offset
                let byte: UInt8 =
                    masked.getInteger(
                        at: index
                    )
                    ?? 0
                masked.setInteger(
                    byte
                        ^ maskingBytes[
                            offset
                                % 4
                        ],
                    at: index
                )
            }

            context.fireChannelRead(
                wrapInboundOut(
                    WebSocketFrame(
                        fin: frame.fin,
                        rsv1: frame.rsv1,
                        rsv2: frame.rsv2,
                        rsv3: frame.rsv3,
                        opcode:
                            frame.opcode,
                        maskKey:
                            WebSocketMaskingKey(
                                maskingBytes
                            ),
                        data: masked
                    )
                )
            )
        }
    }

    private func upgradeHead(
        path: String,
        subprotocol: String? = nil
    ) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        headers.add(
            name: "connection",
            value: "upgrade"
        )
        headers.add(
            name: "upgrade",
            value: "websocket"
        )
        headers.add(
            name:
                "sec-websocket-version",
            value: "13"
        )
        headers.add(
            name:
                "sec-websocket-key",
            value:
                "dGhlIHNhbXBsZSBub25jZQ=="
        )

        if let subprotocol {
            headers.add(
                name:
                    "sec-websocket-protocol",
                value: subprotocol
            )
        }

        return HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: path,
            headers: headers
        )
    }
}
