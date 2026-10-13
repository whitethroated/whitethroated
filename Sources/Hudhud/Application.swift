import NIOCore
import NIOHTTP1
import NIOPosix

public final class Application: @unchecked Sendable {
    private let router = Router()
    private var middleware: [Middleware] = []
    private var compiledResponder: Handler?
    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?

    public init() {}

    public func use(_ middleware: @escaping Middleware) {
        self.middleware.append(middleware)
        compiledResponder = nil
    }

    public func get(
        _ path: String,
        use handler: @escaping @Sendable (Request) -> Response
    ) {
        route(.get, path, use: handler)
    }

    public func get(
        _ path: String,
        use handler: @escaping Handler
    ) {
        router.add(method: .get, path: path, handler: handler)
    }

    public func post(
        _ path: String,
        use handler: @escaping @Sendable (Request) -> Response
    ) {
        route(.post, path, use: handler)
    }

    public func post(
        _ path: String,
        use handler: @escaping Handler
    ) {
        router.add(method: .post, path: path, handler: handler)
    }

    public func put(
        _ path: String,
        use handler: @escaping @Sendable (Request) -> Response
    ) {
        route(.put, path, use: handler)
    }

    public func patch(
        _ path: String,
        use handler: @escaping @Sendable (Request) -> Response
    ) {
        route(.patch, path, use: handler)
    }

    public func delete(
        _ path: String,
        use handler: @escaping @Sendable (Request) -> Response
    ) {
        route(.delete, path, use: handler)
    }

    @discardableResult
    public func listen(
        host: String = "127.0.0.1",
        port: Int = 3000
    ) throws -> Channel {
        compiledResponder = buildMiddlewarePipeline()

        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: System.coreCount
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.backlog,
                value: 256
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
                    .configureHTTPServerPipeline()
                    .flatMap {
                        channel.pipeline.addHandler(
                            HTTPServerHandler(application: self)
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
            throw error
        }
    }

    public func run(
        host: String = "127.0.0.1",
        port: Int = 3000
    ) throws {
        let channel = try listen(host: host, port: port)
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
    }

    func respond(
        to request: Request,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<Response> {
        let responder: Handler

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

    private func buildMiddlewarePipeline() -> Handler {
        var responder: Handler = { [router] request, context in
            router.resolve(request, context: context)
        }

        for current in middleware.reversed() {
            let next = responder

            responder = { request, context in
                current(request, context) { nextRequest in
                    next(nextRequest, context)
                }
            }
        }

        return responder
    }

    private func route(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping @Sendable (Request) -> Response
    ) {
        router.add(method: method, path: path) { request, context in
            context.eventLoop.makeSucceededFuture(
                handler(request)
            )
        }
    }
}
