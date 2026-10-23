import NIOCore
import NIOHTTP1

/// Synchronous route action: runs entirely on the connection event
/// loop and returns a complete response. Must never block, hop event
/// loops, or create Swift Tasks.
public struct RuntimeSyncAction: @unchecked Sendable {
    public var run:
        @Sendable (RuntimeRequest) -> RuntimeResponse

    public init(
        run: @escaping @Sendable (RuntimeRequest)
            -> RuntimeResponse
    ) {
        self.run = run
    }
}

/// Asynchronous route action: invoked on the connection event loop
/// and completes with a response on any event loop. The runtime hops
/// completion back to the connection loop before writing.
///
/// Framework `async` handlers and `concurrent` (Swift concurrency)
/// handlers both map onto this shape; the framework closure owns the
/// Task/future mechanics.
public struct RuntimeAsyncAction: @unchecked Sendable {
    public var run:
        @Sendable (RuntimeRequest, EventLoop)
            -> EventLoopFuture<RuntimeResponse>

    public init(
        run: @escaping @Sendable (RuntimeRequest, EventLoop)
            -> EventLoopFuture<RuntimeResponse>
    ) {
        self.run = run
    }
}

/// Streaming route action: starts request-body streaming, or runs an
/// already-aggregated body through the consumer immediately.
public struct RuntimeStreamingAction: @unchecked Sendable {
    public var begin:
        @Sendable (RuntimeRequest, EventLoop)
            -> RuntimeStreamingStart?
    public var runAggregated:
        @Sendable (RuntimeRequest, EventLoop)
            -> RuntimeDispatchResult

    public init(
        begin: @escaping @Sendable (RuntimeRequest, EventLoop)
            -> RuntimeStreamingStart?,
        runAggregated: @escaping @Sendable (
            RuntimeRequest,
            EventLoop
        ) -> RuntimeDispatchResult
    ) {
        self.begin = begin
        self.runAggregated = runAggregated
    }
}

/// Cached route lookup outcome. Produced once per route per
/// connection by framework lookup, then reused without re-lockup.
public enum RuntimeRouteAction: @unchecked Sendable {
    case prepared(RuntimePreparedResponse)
    case sync(RuntimeSyncAction)
    case async(RuntimeAsyncAction)
    case streaming(RuntimeStreamingAction)
}

/// One-shot dispatch outcome for slow paths (middleware pipeline,
/// aggregated bodies, streaming terminals).
public enum RuntimeDispatchResult: @unchecked Sendable {
    case response(RuntimeResponse)
    case prepared(RuntimePreparedResponse)
    case future(EventLoopFuture<RuntimeResponse>)
}

/// Error-mapping outcome. Cold path only.
public enum RuntimeErrorResult: @unchecked Sendable {
    case response(RuntimeResponse)
    case future(EventLoopFuture<RuntimeResponse>)
}

/// Concrete framework-to-runtime bridge. A plain struct of closures:
/// no protocols, no existentials, no per-request allocation. Built
/// once per application; shared read-only across event loops.
///
/// Event-loop contract for every closure:
/// - invoked on the connection event loop;
/// - `lookup`, `run` (sync), and fixed storages must not hop;
/// - futures may complete on any loop; the runtime hops completion
///   back before writing.
public struct RuntimeDispatcher: @unchecked Sendable {
    public var hasMiddleware: Bool
    public var hasStreamingRoutes: Bool
    public var hasStreamingRoute:
        @Sendable (NIOHTTP1.HTTPMethod) -> Bool

    /// Whether per-connection route caches may store lookup results
    /// for this method. Framework-request-dependent lookups
    /// (conditional prepared responses evaluate headers per request)
    /// answer false so every request resolves against its own headers.
    public var cachesRouteActions:
        @Sendable (NIOHTTP1.HTTPMethod) -> Bool

    public var lookup:
        @Sendable (HTTPRequestHead) -> RuntimeRouteAction
    public var dispatchPipeline:
        @Sendable (RuntimeRequest, EventLoop)
            -> RuntimeDispatchResult
    public var mapError:
        @Sendable (Error, EventLoop, SocketAddress?)
            -> RuntimeErrorResult

    /// Prebuilt fixed responses, shared across connections.
    public var notFound: RuntimePreparedResponse
    public var payloadTooLarge: RuntimePreparedResponse
    public var expectationFailed: RuntimePreparedResponse
    public var internalServerError: RuntimePreparedResponse

    public init(
        hasMiddleware: Bool,
        hasStreamingRoutes: Bool,
        hasStreamingRoute: @escaping @Sendable (
            NIOHTTP1.HTTPMethod
        ) -> Bool,
        cachesRouteActions: @escaping @Sendable (
            NIOHTTP1.HTTPMethod
        ) -> Bool = { _ in true },
        lookup: @escaping @Sendable (HTTPRequestHead)
            -> RuntimeRouteAction,
        dispatchPipeline: @escaping @Sendable (
            RuntimeRequest,
            EventLoop
        ) -> RuntimeDispatchResult,
        mapError: @escaping @Sendable (
            Error,
            EventLoop,
            SocketAddress?
        ) -> RuntimeErrorResult,
        notFound: RuntimePreparedResponse,
        payloadTooLarge: RuntimePreparedResponse,
        expectationFailed: RuntimePreparedResponse,
        internalServerError: RuntimePreparedResponse
    ) {
        self.hasMiddleware = hasMiddleware
        self.hasStreamingRoutes = hasStreamingRoutes
        self.hasStreamingRoute = hasStreamingRoute
        self.cachesRouteActions =
            cachesRouteActions
        self.lookup = lookup
        self.dispatchPipeline = dispatchPipeline
        self.mapError = mapError
        self.notFound = notFound
        self.payloadTooLarge = payloadTooLarge
        self.expectationFailed = expectationFailed
        self.internalServerError = internalServerError
    }
}
