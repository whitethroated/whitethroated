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
                nil
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

        try channel.pipeline
            .syncOperations
            .addHandler(handler)

        return (
            channel,
            connection
        )
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
