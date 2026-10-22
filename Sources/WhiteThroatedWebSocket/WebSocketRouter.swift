import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import WhiteThroated

public enum WebSocketRegistrationError:
    Error,
    Sendable,
    Equatable
{
    case invalidPath
    case duplicatePath(String)
    case invalidSubprotocol(String)
}

public enum WebSocketMessageKind:
    String,
    Sendable,
    Equatable
{
    case text
    case binary
}

public enum WebSocketLifecycleEvent:
    Sendable,
    Equatable
{
    case accepted(
        route: String,
        subprotocol: String?
    )
    case message(
        route: String,
        kind: WebSocketMessageKind,
        bytes: Int
    )
    case closed(
        route: String,
        code: Int?
    )
}

public struct WebSocketConfiguration:
    Sendable
{
    public var maxFrameBytes: Int
    public var maxMessageBytes: Int
    public var closeTimeoutSeconds: Int64

    public init(
        maxFrameBytes: Int = 16 * 1024,
        maxMessageBytes: Int = 1_048_576,
        closeTimeoutSeconds: Int64 = 5
    ) {
        precondition(
            maxFrameBytes > 0,
            "WebSocket maxFrameBytes must be greater than zero"
        )
        precondition(
            maxFrameBytes <= Int(UInt32.max),
            "WebSocket maxFrameBytes exceeds SwiftNIO's decoder limit"
        )
        precondition(
            maxMessageBytes > 0,
            "WebSocket maxMessageBytes must be greater than zero"
        )
        precondition(
            closeTimeoutSeconds > 0,
            "WebSocket close timeout must be greater than zero"
        )

        self.maxFrameBytes = maxFrameBytes
        self.maxMessageBytes = maxMessageBytes
        self.closeTimeoutSeconds =
            closeTimeoutSeconds
    }
}

public struct WebSocketRouteConfiguration:
    Sendable
{
    public var subprotocols: [String]
    public var requireSubprotocol: Bool

    public init(
        subprotocols: [String] = [],
        requireSubprotocol: Bool = false
    ) {
        self.subprotocols = subprotocols
        self.requireSubprotocol =
            requireSubprotocol
    }
}

public struct WebSocketHandlers:
    Sendable
{
    public typealias OpenHandler =
        @Sendable (
            WebSocketConnection,
            Request
        ) -> Void
    public typealias TextHandler =
        @Sendable (
            WebSocketConnection,
            String
        ) -> Void
    public typealias BinaryHandler =
        @Sendable (
            WebSocketConnection,
            ByteBuffer
        ) -> Void
    public typealias PongHandler =
        @Sendable (
            WebSocketConnection,
            ByteBuffer
        ) -> Void
    public typealias CloseHandler =
        @Sendable (
            WebSocketConnection,
            WebSocketClose
        ) -> Void

    public var onOpen: OpenHandler?
    public var onText: TextHandler?
    public var onBinary: BinaryHandler?
    public var onPong: PongHandler?
    public var onClose: CloseHandler?

    public init(
        onOpen: OpenHandler? = nil,
        onText: TextHandler? = nil,
        onBinary: BinaryHandler? = nil,
        onPong: PongHandler? = nil,
        onClose: CloseHandler? = nil
    ) {
        self.onOpen = onOpen
        self.onText = onText
        self.onBinary = onBinary
        self.onPong = onPong
        self.onClose = onClose
    }
}

internal struct WebSocketRoute:
    Sendable
{
    typealias Acceptance =
        @Sendable (
            Request,
            EventLoop
        ) -> EventLoopFuture<Bool>

    let path: String
    let configuration:
        WebSocketRouteConfiguration
    let accept: Acceptance?
    let handlers: WebSocketHandlers
}

public struct WebSocketRouter:
    Sendable
{
    public typealias EventSink =
        @Sendable (
            WebSocketLifecycleEvent
        ) -> Void

    public let configuration:
        WebSocketConfiguration
    public let eventSink: EventSink?

    private var routes: [WebSocketRoute]

    public init(
        configuration:
            WebSocketConfiguration =
                WebSocketConfiguration(),
        eventSink: EventSink? = nil
    ) {
        self.configuration = configuration
        self.eventSink = eventSink
        self.routes = []
    }

    public mutating func on(
        _ path: String,
        configuration:
            WebSocketRouteConfiguration =
                WebSocketRouteConfiguration(),
        accept:
            (@Sendable (Request) -> Bool)? = nil,
        handlers:
            WebSocketHandlers
    ) throws {
        let futureAcceptance:
            WebSocketRoute.Acceptance?

        if let accept {
            futureAcceptance = {
                request,
                eventLoop in

                eventLoop
                    .makeSucceededFuture(
                        accept(request)
                    )
            }
        } else {
            futureAcceptance = nil
        }

        try addRoute(
            path,
            configuration:
                configuration,
            accept:
                futureAcceptance,
            handlers:
                handlers
        )
    }

    public mutating func onFuture(
        _ path: String,
        configuration:
            WebSocketRouteConfiguration =
                WebSocketRouteConfiguration(),
        accept:
            @escaping @Sendable (
                Request,
                EventLoop
            ) -> EventLoopFuture<Bool>,
        handlers:
            WebSocketHandlers
    ) throws {
        try addRoute(
            path,
            configuration:
                configuration,
            accept: accept,
            handlers:
                handlers
        )
    }

    private mutating func addRoute(
        _ path: String,
        configuration:
            WebSocketRouteConfiguration,
        accept:
            WebSocketRoute.Acceptance?,
        handlers:
            WebSocketHandlers
    ) throws {
        guard Self.isValidPath(path) else {
            throw WebSocketRegistrationError
                .invalidPath
        }

        guard
            !routes.contains(
                where: {
                    $0.path == path
                }
            )
        else {
            throw WebSocketRegistrationError
                .duplicatePath(path)
        }

        for subprotocol in
            configuration.subprotocols
        {
            guard
                Self.isValidToken(
                    subprotocol
                )
            else {
                throw WebSocketRegistrationError
                    .invalidSubprotocol(
                        subprotocol
                    )
            }
        }

        routes.append(
            WebSocketRoute(
                path: path,
                configuration:
                    configuration,
                accept: accept,
                handlers: handlers
            )
        )
    }

    public func install(
        on application: Application
    ) {
        let routes = self.routes
        let configuration =
            self.configuration
        let eventSink = self.eventSink

        let upgrader =
            NIOWebSocketServerUpgrader(
                maxFrameSize:
                    configuration
                        .maxFrameBytes,
                automaticErrorHandling: true,
                shouldUpgrade: {
                    channel,
                    head in

                    guard
                        head.method == .GET,
                        let route =
                            Self.match(
                                head: head,
                                routes: routes
                            )
                    else {
                        return channel.eventLoop
                            .makeSucceededFuture(
                                nil
                            )
                    }

                    let request =
                        Request.headOnly(head)
                    let accepted =
                        route.accept?(
                            request,
                            channel.eventLoop
                        )
                        ?? channel.eventLoop
                            .makeSucceededFuture(
                                true
                            )

                    return accepted
                        .hop(
                            to:
                                channel.eventLoop
                        )
                        .map {
                            isAccepted
                                -> HTTPHeaders? in

                            guard isAccepted else {
                                return nil
                            }

                            let selected =
                                Self.selectSubprotocol(
                                    route:
                                        route.configuration,
                                    headers:
                                        head.headers
                                )

                            if
                                route.configuration
                                    .requireSubprotocol,
                                selected == nil
                            {
                                return nil
                            }

                            var headers =
                                HTTPHeaders()

                            if let selected {
                                headers.add(
                                    name:
                                        "sec-websocket-protocol",
                                    value:
                                        selected
                                )
                            }

                            return headers
                        }
                },
                upgradePipelineHandler: {
                    channel,
                    head in

                    guard
                        let route =
                            Self.match(
                                head: head,
                                routes: routes
                            )
                    else {
                        return channel.eventLoop
                            .makeFailedFuture(
                                WebSocketRegistrationError
                                    .invalidPath
                            )
                    }

                    let selected =
                        Self.selectSubprotocol(
                            route:
                                route.configuration,
                            headers:
                                head.headers
                        )
                    let connection =
                        WebSocketConnection(
                            channel: channel,
                            closeTimeoutSeconds:
                                configuration
                                    .closeTimeoutSeconds,
                            subprotocol:
                                selected
                        )
                    let handler =
                        WebSocketFrameHandler(
                            connection:
                                connection,
                            route: route,
                            maxMessageBytes:
                                configuration
                                    .maxMessageBytes,
                            eventSink:
                                eventSink
                        )

                    return channel
                        .setOption(
                            ChannelOptions.autoRead,
                            value: false
                        )
                        .flatMap {
                            channel.pipeline
                                .addHandler(
                                    handler
                                )
                        }
                        .map {
                            eventSink?(
                                .accepted(
                                    route:
                                        route.path,
                                    subprotocol:
                                        selected
                                )
                            )

                            route.handlers
                                .onOpen?(
                                    connection,
                                    Request
                                        .headOnly(
                                            head
                                        )
                                )

                            channel.read()
                        }
                }
            )

        let upgrade:
            NIOHTTPServerUpgradeSendableConfiguration =
                (
                    upgraders: [
                        upgrader,
                    ],
                    completionHandler: {
                        _ in
                    }
                )

        application
            .installHTTPServerUpgrade(
                upgrade
            )
    }

    private static func match(
        head: HTTPRequestHead,
        routes: [WebSocketRoute]
    ) -> WebSocketRoute? {
        let target = path(from: head.uri)

        return routes.first {
            $0.path == target
        }
    }

    private static func path(
        from uri: String
    ) -> String {
        let bytes = uri.utf8

        guard
            let query =
                bytes.firstIndex(
                    of: 63
                )
        else {
            return uri
        }

        return String(
            decoding:
                bytes[..<query],
            as: UTF8.self
        )
    }

    private static func selectSubprotocol(
        route:
            WebSocketRouteConfiguration,
        headers: HTTPHeaders
    ) -> String? {
        guard
            !route.subprotocols.isEmpty
        else {
            return nil
        }

        var offered = Set<String>()

        for value in
            headers[
                "sec-websocket-protocol"
            ]
        {
            for item in
                value.split(
                    separator: ","
                )
            {
                let token =
                    item.trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

                if !token.isEmpty {
                    offered.insert(token)
                }
            }
        }

        for supported in
            route.subprotocols
        where offered.contains(supported) {
            return supported
        }

        return nil
    }

    private static func isValidPath(
        _ path: String
    ) -> Bool {
        path.hasPrefix("/")
        && !path.contains("?")
        && !path.contains("#")
        && !path.contains("\r")
        && !path.contains("\n")
    }

    private static func isValidToken(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        for byte in value.utf8 {
            switch byte {
            case 33,
                 35...39,
                 42...43,
                 45...46,
                 48...57,
                 65...90,
                 94...122,
                 124,
                 126:
                continue
            default:
                return false
            }
        }

        return true
    }
}

public extension Application {
    func use(webSockets: WebSocketRouter) {
        webSockets.install(on: self)
    }
}
