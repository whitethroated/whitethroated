import NIOCore
import NIOHTTP1
import WhiteThroatedRuntime

extension Application {
    internal func makeRuntimeConfiguration(
        maxRequestBodyBytes: Int? = nil
    ) -> RuntimeServerConfiguration {
        RuntimeServerConfiguration(
            eventLoopThreads:
                configuration.eventLoopThreads,
            backlog: configuration.backlog,
            maxRequestBodyBytes:
                maxRequestBodyBytes
                ?? configuration.maxRequestBodyBytes,
            useTier1HTTP1: configuration
                .useTier1HTTP1Experimental,
            acceptedChannelInitializer:
                acceptedChannelInitializer,
            httpServerUpgrade:
                httpServerUpgrade
        )
    }

    /// Builds the framework-to-runtime bridge. Captures the compiled
    /// middleware responder when available so serving never rebuilds
    /// it per request; falls back to building on the spot for
    /// EmbeddedChannel tests that never call `listen`.
    internal func makeRuntimeDispatcher() -> RuntimeDispatcher {
        let responder =
            compiledResponder
            ?? buildMiddlewarePipeline()

        return RuntimeDispatcher(
            hasMiddleware: hasMiddleware,
            hasStreamingRoutes: hasStreamingRoutes,
            hasStreamingRoute: { method in
                self.hasStreamingRoute(
                    for: method
                )
            },
            lookup: { head in
                self.lookupRuntimeAction(
                    head: head
                )
            },
            dispatchPipeline: {
                [responder] request, eventLoop in
                let frameworkRequest = Request(
                    head: request.head,
                    body: request.body
                )
                let context = Context(
                    eventLoop: eventLoop,
                    remoteAddress:
                        request.remoteAddress
                )

                return responder(
                    frameworkRequest,
                    context
                ).asRuntimeDispatchResult(
                    on: eventLoop
                )
            },
            mapError: { error, eventLoop, address in
                self.respondRuntimeError(
                    error,
                    on: eventLoop,
                    remoteAddress: address
                )
            },
            notFound: PreparedResponse
                .defaultNotFoundStorage
                .runtimeStorage,
            payloadTooLarge: PreparedResponse
                .text(
                    "Payload Too Large",
                    status: .payloadTooLarge
                )
                .storage
                .runtimeStorage,
            expectationFailed: PreparedResponse
                .text(
                    "Expectation Failed",
                    status: .expectationFailed
                )
                .storage
                .runtimeStorage,
            internalServerError: PreparedResponse
                .text(
                    "Internal Server Error",
                    status: .internalServerError
                )
                .storage
                .runtimeStorage
        )
    }

    @inline(__always)
    private func lookupRuntimeAction(
        head: HTTPRequestHead
    ) -> RuntimeRouteAction {
        switch lookupTransport(head: head) {
        case .prepared(let storage):
            return .prepared(
                storage.runtimeStorage
            )

        case .conditionalPrepared(
            let tag,
            let response,
            let notModified
        ):
            return .prepared(
                (
                    IfNoneMatchMatcher.matches(
                        headers: head.headers,
                        tag: tag
                    )
                    ? notModified
                    : response
                ).runtimeStorage
            )

        case .synchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            return .sync(
                RuntimeSyncAction { request in
                    handler(
                        Request(
                            head: request.head,
                            body: request.body,
                            routeParameterNames:
                                parameterNames,
                            routeParameterRanges:
                                parameterRanges
                        )
                    ).runtimeResponse
                }
            )

        case .asynchronous(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            return .async(
                RuntimeAsyncAction {
                    request, eventLoop in
                    handler(
                        Request(
                            head: request.head,
                            body: request.body,
                            routeParameterNames:
                                parameterNames,
                            routeParameterRanges:
                                parameterRanges
                        ),
                        Context(
                            eventLoop: eventLoop,
                            remoteAddress:
                                request.remoteAddress
                        )
                    ).map {
                        $0.runtimeResponse
                    }
                }
            )

        case .concurrent(
            let handler,
            let parameterNames,
            let parameterRanges
        ):
            return .async(
                RuntimeAsyncAction {
                    request, eventLoop in
                    let frameworkRequest = Request(
                        head: request.head,
                        body: request.body,
                        routeParameterNames:
                            parameterNames,
                        routeParameterRanges:
                            parameterRanges
                    )
                    let promise = eventLoop
                        .makePromise(
                            of: RuntimeResponse.self
                        )
                    promise.completeWithTask {
                        try await handler(
                            frameworkRequest
                        ).runtimeResponse
                    }

                    return promise.futureResult
                }
            )

        case .streaming(
            let handler,
            let routeMaxBodyBytes,
            let parameterNames,
            let parameterRanges
        ):
            return .streaming(
                RuntimeStreamingAction(
                    begin: {
                        request, eventLoop in
                        self.beginRuntimeStreaming(
                            request: request,
                            handler: handler,
                            routeMaxBodyBytes:
                                routeMaxBodyBytes,
                            parameterNames:
                                parameterNames,
                            parameterRanges:
                                parameterRanges,
                            on: eventLoop
                        )
                    },
                    runAggregated: {
                        request, eventLoop in
                        self.runAggregatedRuntimeStreaming(
                            request: request,
                            handler: handler,
                            parameterNames:
                                parameterNames,
                            parameterRanges:
                                parameterRanges,
                            on: eventLoop
                        )
                    }
                )
            )

        case .notFound:
            return .prepared(
                PreparedResponse
                    .defaultNotFoundStorage
                    .runtimeStorage
            )
        }
    }

    private func beginRuntimeStreaming(
        request: RuntimeRequest,
        handler: @escaping StreamingHandler,
        routeMaxBodyBytes: Int?,
        parameterNames: RouteParameterNames,
        parameterRanges: RouteParameterRanges,
        on eventLoop: EventLoop
    ) -> RuntimeStreamingStart? {
        let maxBodyBytes =
            routeMaxBodyBytes
            ?? configuration.maxRequestBodyBytes
        let declaredBodyTooLarge =
            HTTPContentLength.declaredExceedsLimit(
                request.head.headers,
                limit: maxBodyBytes
            )
        let registration = RuntimeStreamRegistration(
            eventLoop: eventLoop
        )
        let context = Context(
            eventLoop: eventLoop,
            remoteAddress:
                request.remoteAddress,
            streamingRegistration: registration
        )
        let frameworkRequest = Request(
            head: request.head,
            body: request.body,
            routeParameterNames: parameterNames,
            routeParameterRanges: parameterRanges
        )

        let terminal: InternalHandler

        if declaredBodyTooLarge {
            terminal = { _, _ in
                registration.bypassIfPending()
                return .immediate(
                    .payloadTooLarge()
                )
            }
        } else {
            terminal = {
                request,
                context in

                let consumer = handler(
                    StreamRequest(request),
                    context
                )
                let session = BodyStreamSession(
                    consumer: consumer,
                    eventLoop: context.eventLoop
                )
                context.streamingRegistration?
                    .register(
                        session.bridgeToRuntime()
                    )

                return .streaming(session)
            }
        }

        let result = runStreamingMiddleware(
            index: 0,
            request: frameworkRequest,
            context: context,
            terminal: terminal
        )

        let runtimeResult: RuntimeDispatchResult

        switch result {
        case .immediate, .prepared:
            registration.bypassIfPending()
            runtimeResult =
                result.asRuntimeDispatchResult(
                    on: eventLoop
                )

        case .streaming:
            runtimeResult =
                result.asRuntimeDispatchResult(
                    on: eventLoop
                )

        case .future(let future):
            future.whenComplete { _ in
                registration.bypassIfPending()
            }
            runtimeResult =
                result.asRuntimeDispatchResult(
                    on: eventLoop
                )
        }

        return RuntimeStreamingStart(
            result: runtimeResult,
            registration: registration,
            maxBodyBytes: maxBodyBytes,
            declaredBodyTooLarge:
                declaredBodyTooLarge
        )
    }

    private func runAggregatedRuntimeStreaming(
        request: RuntimeRequest,
        handler: @escaping StreamingHandler,
        parameterNames: RouteParameterNames,
        parameterRanges: RouteParameterRanges,
        on eventLoop: EventLoop
    ) -> RuntimeDispatchResult {
        let frameworkRequest = Request(
            head: request.head,
            body: emptyRequestBody,
            routeParameterNames: parameterNames,
            routeParameterRanges: parameterRanges
        )
        let context = Context(
            eventLoop: eventLoop,
            remoteAddress:
                request.remoteAddress
        )
        let consumer = handler(
            StreamRequest(frameworkRequest),
            context
        )
        let session = BodyStreamSession(
            consumer: consumer,
            eventLoop: eventLoop
        )
        let body = request.body

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

                    return .future(
                        responseFuture.map {
                            $0.runtimeResponse
                        }
                    )
                }
            } catch {
                session.fail(error)
                return .future(
                    session.responseFuture.map {
                        $0.runtimeResponse
                    }
                )
            }
        }

        session.finish()
        return .future(
            session.responseFuture.map {
                $0.runtimeResponse
            }
        )
    }

    private func respondRuntimeError(
        _ error: Error,
        on eventLoop: EventLoop,
        remoteAddress: SocketAddress?
    ) -> RuntimeErrorResult {
        let mapped =
            mapRuntimeRequestStreamError(
                error
            )

        guard let errorHandler else {
            return .response(
                Response.internalServerError()
                    .runtimeResponse
            )
        }

        let context = Context(
            eventLoop: eventLoop,
            remoteAddress: remoteAddress
        )

        switch errorHandler {
        case .synchronous(let handler):
            return .response(
                handler(
                    mapped,
                    context
                ).runtimeResponse
            )

        case .asynchronous(let handler):
            return .future(
                handler(
                    mapped,
                    context
                ).hop(
                    to: eventLoop
                ).map {
                    $0.runtimeResponse
                }
            )

        case .concurrent(let handler):
            let promise = eventLoop.makePromise(
                of: RuntimeResponse.self
            )
            promise.completeWithTask {
                try await handler(
                    mapped,
                    context
                ).runtimeResponse
            }

            return .future(
                promise.futureResult
            )
        }
    }
}
