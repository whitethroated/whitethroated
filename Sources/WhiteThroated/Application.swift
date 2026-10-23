import NIOCore
import NIOHTTP1
import WhiteThroatedRuntime

public typealias AcceptedChannelInitializer =
    @Sendable (Channel) -> EventLoopFuture<Void>

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
    internal let emptyRequestBody =
        ByteBufferAllocator().buffer(capacity: 0)
    private var middleware: [MiddlewareEntry] = []
    internal var errorHandler: ErrorHandlerEntry?
    internal var compiledResponder: InternalHandler?
    private var runtimeServer: RuntimeServer?
    internal var acceptedChannelInitializer:
        AcceptedChannelInitializer?
    internal var httpServerUpgrade:
        NIOHTTPServerUpgradeSendableConfiguration?
    internal var upgradeErrorFilter:
        (@Sendable (Error) -> Bool)?
    private var configurationFrozen = false

    internal var hasStreamingRoutes: Bool {
        router.hasStreamingRoutes
    }

    internal var hasMiddleware: Bool {
        !middleware.isEmpty
    }

    @inline(__always)
    internal func hasStreamingRoute(
        for method: NIOHTTP1.HTTPMethod
    ) -> Bool {
        router.hasStreamingRoute(
            for: method
        )
    }

    @inline(__always)
    internal func hasRequestDependentRoute(
        for method: NIOHTTP1.HTTPMethod
    ) -> Bool {
        router.hasRequestDependentRoute(
            for: method
        )
    }

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

    /// Installs one setup-time initializer for newly accepted
    /// connections before the HTTP pipeline is configured.
    ///
    /// Optional transport capabilities such as direct TLS use this
    /// hook. Core-only applications leave it nil and pay no
    /// request-time cost.
    public func installAcceptedChannelInitializer(
        _ initializer: @escaping
            AcceptedChannelInitializer
    ) {
        requireConfigurationPhase()

        precondition(
            acceptedChannelInitializer == nil,
            "Only one accepted-channel initializer can be installed"
        )

        acceptedChannelInitializer =
            initializer
    }

    /// Installs one setup-time HTTP protocol upgrade
    /// configuration. Registering an upgrade forces the stock
    /// SwiftNIO HTTP/1 pipeline for accepted connections.
    public func installHTTPServerUpgrade(
        _ upgrade:
            NIOHTTPServerUpgradeSendableConfiguration
    ) {
        requireConfigurationPhase()

        precondition(
            httpServerUpgrade == nil,
            "Only one HTTP server upgrade configuration can be installed"
        )

        httpServerUpgrade = upgrade
    }

    /// Installs one setup-time filter for errors raised by the
    /// pipeline's upgrade machinery.
    ///
    /// Upgrade capability owners use this hook so a refused (or
    /// protocol-invalid) upgrade request is downgraded into normal
    /// request dispatch. The re-delivered request receives its normal
    /// HTTP response with `Connection: close`, then the connection
    /// closes after flushing: NIO's decoder cannot resume parsing
    /// after an upgrade-flagged request.
    /// Errors outside the installed filter, or errors that surface
    /// mid-request, still close the connection as before.
    public func installUpgradeErrorFilter(
        _ filter: @escaping @Sendable (Error) -> Bool
    ) {
        requireConfigurationPhase()

        precondition(
            upgradeErrorFilter == nil,
            "Only one upgrade error filter can be installed"
        )

        upgradeErrorFilter = filter
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

    public func onError(
        _ handler: @escaping SyncErrorHandler
    ) {
        requireConfigurationPhase()
        errorHandler = .synchronous(handler)
    }

    public func onError(
        _ handler: @escaping ErrorHandler
    ) {
        requireConfigurationPhase()
        errorHandler = .asynchronous(handler)
    }

    public func onError(
        _ handler: @escaping AsyncErrorHandler
    ) {
        requireConfigurationPhase()
        errorHandler = .concurrent(handler)
    }

    @inline(__always)
    internal func respondError(
        _ error: Error,
        on eventLoop: EventLoop,
        channel: Channel? = nil
    ) -> ErrorResponderResult {
        guard let errorHandler else {
            return .immediate(
                .internalServerError()
            )
        }

        let context = Context(
            eventLoop: eventLoop,
            remoteAddress:
                channel?.remoteAddress
        )

        switch errorHandler {
        case .synchronous(let handler):
            return .immediate(
                handler(
                    error,
                    context
                )
            )

        case .asynchronous(let handler):
            return .future(
                handler(
                    error,
                    context
                ).hop(
                    to: eventLoop
                )
            )

        case .concurrent(let handler):
            let promise = eventLoop.makePromise(
                of: Response.self
            )
            promise.completeWithTask {
                try await handler(
                    error,
                    context
                )
            }

            return .future(
                promise.futureResult
            )
        }
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

    public func all(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        requireConfigurationPhase()

        for method in Self.commonMethods {
            router.add(
                method: method,
                path: path,
                asyncHandler: handler
            )
        }
    }

    public func onStream(
        _ method: HTTPMethod,
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        requireConfigurationPhase()

        if let maxBodyBytes {
            precondition(
                maxBodyBytes >= 0,
                "maxBodyBytes must be zero or greater"
            )
        }

        router.add(
            method: method,
            path: path,
            streamingHandler: handler,
            maxBodyBytes: maxBodyBytes
        )
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

    public func on(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping AsyncHandler
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
        response: PreparedResponse,
        etag: EntityTag
    ) {
        requireConfigurationPhase()

        router.add(
            method: .get,
            path: path,
            conditionalPreparedResponse:
                response,
            etag: etag
        )
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

    public func get(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        route(.get, path, use: handler)
    }

    public func postStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        onStream(
            .post,
            path,
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
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

    public func post(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        route(.post, path, use: handler)
    }

    public func putStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        onStream(
            .put,
            path,
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
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

    public func put(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        route(.put, path, use: handler)
    }

    public func patchStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        onStream(
            .patch,
            path,
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
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

    public func patch(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        route(.patch, path, use: handler)
    }

    public func deleteStream(
        _ path: String,
        maxBodyBytes: Int? = nil,
        use handler: @escaping StreamingHandler
    ) {
        onStream(
            .delete,
            path,
            maxBodyBytes: maxBodyBytes,
            use: handler
        )
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

    public func delete(
        _ path: String,
        use handler: @escaping AsyncHandler
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

    public func head(
        _ path: String,
        use handler: @escaping AsyncHandler
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

    public func options(
        _ path: String,
        use handler: @escaping AsyncHandler
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

    public func connect(
        _ path: String,
        use handler: @escaping AsyncHandler
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

    public func trace(
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        route(.trace, path, use: handler)
    }

    @inline(__always)
    internal func lookupTransport(
        head: HTTPRequestHead
    ) -> RouterMatch {
        router.lookup(
            method: head.method,
            uri: head.uri.utf8
        )
    }

    // Streaming begin moved to Application+RuntimeDispatcher
    // (beginRuntimeStreaming), which builds runtime-typed transport
    // state directly. The middleware chain below is shared.

    func runStreamingMiddleware(
        index: Int,
        request: Request,
        context: Context,
        terminal: @escaping InternalHandler
    ) -> ResponderResult {
        guard index < middleware.count else {
            return terminal(
                request,
                context
            )
        }

        let entry = middleware[index]

        switch entry {
        case .fast(let current):
            return current(
                request,
                context
            ) { nextRequest in
                MiddlewareResult(
                    self.runStreamingMiddleware(
                        index: index + 1,
                        request: nextRequest,
                        context: context,
                        terminal: terminal
                    )
                )
            }.responderResult

        case .asynchronous(let current):
            return .future(
                current(
                    request,
                    context
                ) { nextRequest in
                    self.runStreamingMiddleware(
                        index: index + 1,
                        request: nextRequest,
                        context: context,
                        terminal: terminal
                    ).asFuture(
                        on: context.eventLoop
                    )
                }.hop(
                    to: context.eventLoop
                )
            )
        }
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

        let server = RuntimeServer(
            configuration:
                makeRuntimeConfiguration(),
            dispatcher:
                makeRuntimeDispatcher()
        )

        do {
            let channel = try server.start(
                host: host,
                port: port
            )

            self.runtimeServer = server
            return channel
        } catch {
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
        if let server = runtimeServer {
            try server.stop()
            runtimeServer = nil
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
        on eventLoop: EventLoop,
        channel: Channel? = nil
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
            Context(
                eventLoop: eventLoop,
                remoteAddress:
                    channel?.remoteAddress
            )
        )
    }

    @inline(__always)
    func respondTransport(
        head: HTTPRequestHead,
        body: ByteBuffer,
        on eventLoop: EventLoop,
        channel: Channel? = nil
    ) -> ResponderResult {
        guard middleware.isEmpty else {
            let request = Request(
                head: head,
                body: body
            )

            return respondFast(
                to: request,
                on: eventLoop,
                channel: channel
            )
        }

        return respondTransport(
            match: lookupTransport(
                head: head
            ),
            head: head,
            body: body,
            on: eventLoop,
            channel: channel
        )
    }

    @inline(__always)
    internal func respondTransport(
        match: RouterMatch,
        head: HTTPRequestHead,
        body: ByteBuffer,
        on eventLoop: EventLoop,
        channel: Channel? = nil
    ) -> ResponderResult {
        switch match {
        case .prepared(let prepared):
            return .prepared(prepared)

        case .conditionalPrepared(
            let tag,
            let response,
            let notModified
        ):
            return .prepared(
                IfNoneMatchMatcher.matches(
                    headers: head.headers,
                    tag: tag
                )
                ? notModified
                : response
            )

        case .synchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            let request = Request(
                head: head,
                body: body,
                routeParameterNames: parameterNames,
                routeParameterRanges: parameterRanges
            )

            return .immediate(
                handler(request)
            )

        case .asynchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            let request = Request(
                head: head,
                body: body,
                routeParameterNames: parameterNames,
                routeParameterRanges: parameterRanges
            )

            return .future(
                handler(
                    request,
                    Context(
                        eventLoop: eventLoop,
                        remoteAddress:
                            channel?.remoteAddress
                    )
                )
            )

        case .concurrent(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            let asyncRequest = Request(
                head: head,
                body: body,
                routeParameterNames: parameterNames,
                routeParameterRanges: parameterRanges
            )
            let promise = eventLoop.makePromise(
                of: Response.self
            )
            promise.completeWithTask {
                try await handler(asyncRequest)
            }

            return .future(promise.futureResult)

        case .streaming(
            let handler,
            _,
            let parameterNames,
            let parameterRanges
        ):
            let request = Request(
                head: head,
                body: emptyRequestBody,
                routeParameterNames: parameterNames,
                routeParameterRanges: parameterRanges
            )
            let context = Context(
                eventLoop: eventLoop,
                remoteAddress:
                    channel?.remoteAddress
            )
            let consumer = handler(
                StreamRequest(request),
                context
            )
            let session = BodyStreamSession(
                consumer: consumer,
                eventLoop: eventLoop
            )

            if body.readableBytes > 0 {
                do {
                    if let chunkFuture =
                        try session.receive(body)
                    {
                        let responseFuture =
                            chunkFuture.hop(
                                to: eventLoop
                            ).flatMap {
                                session.finish()
                                return session.responseFuture
                            }.flatMapError { error in
                                session.fail(error)
                                return eventLoop
                                    .makeFailedFuture(
                                        error
                                    )
                            }

                        return .future(responseFuture)
                    }
                } catch {
                    session.fail(error)
                    return .future(
                        session.responseFuture
                    )
                }
            }

            session.finish()
            return .future(
                session.responseFuture
            )

        case .notFound:
            return .prepared(
                PreparedResponse
                    .defaultNotFoundStorage
            )
        }
    }


    func buildMiddlewarePipeline() -> InternalHandler {
        let terminal: InternalHandler = {
            [router] request, context in

            router.resolve(
                request,
                context: context
            )
        }

        guard !middleware.isEmpty else {
            return terminal
        }

        typealias MiddlewareResponder =
            @Sendable (
                Request,
                Context
            ) -> MiddlewareResult

        var responder: MiddlewareResponder = {
            request,
            context in

            MiddlewareResult(
                terminal(
                    request,
                    context
                )
            )
        }

        for entry in middleware.reversed() {
            let next = responder

            switch entry {
            case .fast(let current):
                responder = {
                    request,
                    context in

                    current(
                        request,
                        context
                    ) { nextRequest in
                        next(
                            nextRequest,
                            context
                        )
                    }
                }

            case .asynchronous(let current):
                responder = {
                    request,
                    context in

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

        let compiled = responder

        return {
            request,
            context in

            compiled(
                request,
                context
            ).responderResult
        }
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

    private func route(
        _ method: HTTPMethod,
        _ path: String,
        use handler: @escaping AsyncHandler
    ) {
        requireConfigurationPhase()

        router.add(
            method: method,
            path: path,
            asyncHandler: handler
        )
    }
}
