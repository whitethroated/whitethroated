import NIOCore
import NIOHTTP1
import NIOPosix

private enum MiddlewareEntry {
    case asynchronous(Middleware)
    case fast(FastMiddleware)
}

public final class Application: @unchecked Sendable {
    public let configuration: ServerConfiguration

    private static let commonMethods: [HTTPMethod] = [
        .get,
        .post,
        .put,
        .patch,
        .delete,
        .head,
        .options,
        .connect,
        .trace
    ]

    private let router = Router()
    private var middleware: [MiddlewareEntry] = []
    private var compiledResponder: InternalHandler?
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var configurationFrozen = false

    public init(
        configuration: ServerConfiguration = ServerConfiguration()
    ) {
        self.configuration = configuration
    }

    public func group(_ prefix: String) -> RouteGroup {
        RouteGroup(
            application: self,
            prefix: prefix
        )
    }

    public func use(_ middleware: @escaping Middleware) {
        requireConfigurationPhase()

        self.middleware.append(
            .asynchronous(middleware)
        )
        compiledResponder = nil
    }

    public func useFast(
        _ middleware: @escaping FastMiddleware
    ) {
        requireConfigurationPhase()

        self.middleware.append(
            .fast(middleware)
        )
        compiledResponder = nil
    }


    public func all(
        _ path: String,
        response: PreparedResponse
    ) {
        requireConfigurationPhase()

        for method in Self.commonMethods {
            router.add(
                method: method,
                path: path,
                preparedResponse: response
            )
        }
    }

    public func all(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        requireConfigurationPhase()

        for method in Self.commonMethods {
            router.add(
                method: method,
                path: path,
                syncHandler: handler
            )
        }
    }

    public func all(
        _ path: String,
        use handler: @escaping Handler
    ) {
        requireConfigurationPhase()

        for method in Self.commonMethods {
            router.add(
                method: method,
                path: path,
                handler: handler
            )
        }
    }

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        response: PreparedResponse
    ) {
        requireConfigurationPhase()

        router.add(
            method: method,
            path: path,
            preparedResponse: response
        )
    }

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(method, path, use: handler)
    }

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(method, path, use: handler)
    }

    public func get(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.get, path, response: response)
    }

    public func get(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.get, path, use: handler)
    }

    public func get(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.get, path, use: handler)
    }

    public func post(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.post, path, response: response)
    }

    public func post(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.post, path, use: handler)
    }

    public func post(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.post, path, use: handler)
    }

    public func put(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.put, path, response: response)
    }

    public func put(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.put, path, use: handler)
    }

    public func put(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.put, path, use: handler)
    }

    public func patch(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.patch, path, response: response)
    }

    public func patch(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.patch, path, use: handler)
    }

    public func patch(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.patch, path, use: handler)
    }

    public func delete(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.delete, path, response: response)
    }

    public func delete(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.delete, path, use: handler)
    }

    public func delete(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.delete, path, use: handler)
    }

    public func head(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.head, path, response: response)
    }

    public func head(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.head, path, use: handler)
    }

    public func head(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.head, path, use: handler)
    }

    public func options(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.options, path, response: response)
    }

    public func options(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.options, path, use: handler)
    }

    public func options(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.options, path, use: handler)
    }

    public func connect(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.connect, path, response: response)
    }

    public func connect(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.connect, path, use: handler)
    }

    public func connect(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.connect, path, use: handler)
    }

    public func trace(
        _ path: String,
        response: PreparedResponse
    ) {
        on(.trace, path, response: response)
    }

    public func trace(
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        route(.trace, path, use: handler)
    }

    public func trace(
        _ path: String,
        use handler: @escaping Handler
    ) {
        route(.trace, path, use: handler)
    }

    @discardableResult
    public func listen(
        host: String = "127.0.0.1",
        port: Int = 3000
    ) throws -> Channel {
        guard !configurationFrozen else {
            throw ApplicationError.alreadyRunning
        }

        configurationFrozen = true
        compiledResponder = buildMiddlewarePipeline()

        let group = MultiThreadedEventLoopGroup(
            numberOfThreads:
                configuration.eventLoopThreads ?? System.coreCount
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.backlog,
                value: configuration.backlog
            )
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelOption(
                ChannelOptions.socketOption(.tcp_nodelay),
                value: 1
            )
            .childChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelInitializer { channel in
                channel.pipeline
                    .configureHTTPServerPipeline(
                        withPipeliningAssistance: true,
                        withErrorHandling: true
                    )
                    .flatMap {
                        channel.pipeline.addHandler(
                            HTTPServerHandler(
                                application: self,
                                maxRequestBodyBytes:
                                    self.configuration.maxRequestBodyBytes
                            )
                        )
                    }
            }

        do {
            let channel = try bootstrap
                .bind(host: host, port: port)
                .wait()

            self.group = group
            self.serverChannel = channel
            return channel
        } catch {
            try? group.syncShutdownGracefully()
            configurationFrozen = false
            throw error
        }
    }

    public func run(
        host: String = "127.0.0.1",
        port: Int = 3000
    ) throws {
        let channel = try listen(host: host, port: port)

        defer {
            try? shutdown()
        }

        try channel.closeFuture.wait()
    }

    public func shutdown() throws {
        if let channel = serverChannel {
            try channel.close().wait()
            serverChannel = nil
        }

        if let group {
            try group.syncShutdownGracefully()
            self.group = nil
        }

        configurationFrozen = false
    }

    @inline(__always)
    private func requireConfigurationPhase() {
        precondition(
            !configurationFrozen,
            "Routes and middleware must be registered before the server starts"
        )
    }

    func respond(
        to request: Request,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Response> {
        respondFast(
            to: request,
            on: eventLoop
        ).asFuture(on: eventLoop)
    }

    func respondFast(
        to request: Request,
        on eventLoop: EventLoop
    ) -> ResponderResult {
        let responder: InternalHandler

        if let compiledResponder {
            responder = compiledResponder
        } else {
            let built = buildMiddlewarePipeline()
            compiledResponder = built
            responder = built
        }

        return responder(
            request,
            Context(eventLoop: eventLoop)
        )
    }

    @inline(__always)
    func respondTransport(
        head: HTTPRequestHead,
        body: ByteBuffer,
        on eventLoop: EventLoop
    ) -> ResponderResult {
        guard middleware.isEmpty else {
            let request = Request(
                head: head,
                body: body
            )

            return respondFast(
                to: request,
                on: eventLoop
            )
        }

        switch router.lookup(
            method: head.method,
            uri: head.uri.utf8
        ) {
        case .prepared(let prepared):
            return .prepared(prepared)

        case .synchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            var request = Request(
                head: head,
                body: body
            )
            request.routeParameterNames =
                parameterNames
            request.routeParameterRanges =
                parameterRanges

            return .immediate(
                handler(request)
            )

        case .asynchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            var request = Request(
                head: head,
                body: body
            )
            request.routeParameterNames =
                parameterNames
            request.routeParameterRanges =
                parameterRanges

            return .future(
                handler(
                    request,
                    Context(eventLoop: eventLoop)
                )
            )

        case .notFound:
            return .immediate(.notFound())
        }
    }

    private func buildMiddlewarePipeline() -> InternalHandler {
        var responder: InternalHandler = {
            [router] request, context in

            router.resolve(
                request,
                context: context
            )
        }

        for entry in middleware.reversed() {
            let next = responder

            switch entry {
            case .fast(let current):
                responder = { request, context in
                    current(
                        request,
                        context
                    ) { nextRequest in
                        MiddlewareResult(
                            next(
                                nextRequest,
                                context
                            )
                        )
                    }.responderResult
                }

            case .asynchronous(let current):
                responder = { request, context in
                    .future(
                        current(
                            request,
                            context
                        ) { nextRequest in
                            next(
                                nextRequest,
                                context
                            ).asFuture(
                                on: context.eventLoop
                            )
                        }
                    )
                }
            }
        }

        return responder
    }

    private func route(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping SyncHandler
    ) {
        requireConfigurationPhase()

        router.add(
            method: method,
            path: path,
            syncHandler: handler
        )
    }

    private func route(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping Handler
    ) {
        requireConfigurationPhase()

        router.add(
            method: method,
            path: path,
            handler: handler
        )
    }
}
