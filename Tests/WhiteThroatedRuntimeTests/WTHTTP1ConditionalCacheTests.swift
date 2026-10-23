import XCTest
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import WhiteThroatedRuntime

final class WTHTTP1ConditionalCacheTests: XCTestCase {
    func testDefaultDispatcherCachesRouteActions() {
        let dispatcher = Self.makeDispatcher(
            cachesRouteActions: { _ in true },
            lookup: { _ in
                .prepared(
                    Self.prepared(
                        status: .ok,
                        body: "x"
                    )
                )
            }
        )

        XCTAssertTrue(
            dispatcher.cachesRouteActions(.GET)
        )
    }

    func testRequestDependentActionsResolveEveryRequest() throws
    {
        // The fixture lookup evaluates the conditional header per call
        // and the method is flagged non-cacheable — exactly what the
        // framework bridge does for conditional prepared responses. The
        // connection must therefore re-resolve on every request and
        // must never serve a pinned 200/304 decision to the other kind
        // of request.
        let lookups = LookupCounter()
        let fullBody = Self.prepared(
            status: .ok,
            body: "ready"
        )
        let bodyless = Self.prepared(
            status: .notModified,
            body: "ready"
        )

        let dispatcher = Self.makeDispatcher(
            cachesRouteActions: { _ in false },
            lookup: { head in
                lookups.increment()

                let matches =
                    head.headers.first(
                        name: "if-none-match"
                    ) == "\"status-v1\""

                return .prepared(
                    matches
                        ? bodyless
                        : fullBody
                )
            }
        )

        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(
            loop: loop
        )
        defer {
            _ = try? channel.finish()
        }

        try channel.pipeline.syncOperations
            .addHandler(
                WTHTTP1ConnectionHandler(
                    dispatcher: dispatcher,
                    configuration: RuntimeServerConfiguration(
                        maxRequestBodyBytes: 1_048_576
                    )
                )
            )
        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        let first = try self.send(
            channel,
            loop,
            "GET /status HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        XCTAssertTrue(
            first.contains("200"),
            "expected 200, got: \(first)"
        )
        XCTAssertTrue(first.contains("ready"))

        let second = try self.send(
            channel,
            loop,
            "GET /status HTTP/1.1\r\nHost: x\r\nIf-None-Match: \"status-v1\"\r\n\r\n"
        )
        XCTAssertTrue(
            second.contains("304"),
            "expected 304, got: \(second)"
        )
        XCTAssertFalse(second.contains("ready"))

        let third = try self.send(
            channel,
            loop,
            "GET /status HTTP/1.1\r\nHost: x\r\n\r\n"
        )
        XCTAssertTrue(
            third.contains("200"),
            "expected 200, got: \(third)"
        )
        XCTAssertTrue(third.contains("ready"))

        // Every request must have resolved its own headers instead of
        // reusing a cached prepared decision.
        XCTAssertEqual(
            lookups.value,
            3
        )
    }

    private func send(
        _ channel: EmbeddedChannel,
        _ loop: EmbeddedEventLoop,
        _ request: String
    ) throws -> String {
        try channel.writeInbound(
            ByteBuffer(
                string: request
            )
        )
        loop.run()

        var serialized = ""
        while
            let buffer =
                try channel.readOutbound(
                    as: ByteBuffer.self
                )
        {
            serialized += String(
                decoding: buffer
                    .readableBytesView,
                as: UTF8.self
            )
        }
        loop.run()

        return serialized
    }

    private static func makeDispatcher(
        cachesRouteActions: @escaping @Sendable (
            NIOHTTP1.HTTPMethod
        ) -> Bool,
        lookup: @escaping @Sendable (HTTPRequestHead)
            -> RuntimeRouteAction
    ) -> RuntimeDispatcher {
        RuntimeDispatcher(
            hasMiddleware: false,
            hasStreamingRoutes: false,
            hasStreamingRoute: { _ in false },
            cachesRouteActions:
                cachesRouteActions,
            lookup: lookup,
            dispatchPipeline: { request, _ in
                .response(
                    RuntimeResponse(
                        status: .internalServerError,
                        headers: HTTPHeaders(),
                        body: .buffer(
                            ByteBuffer(
                                string: "unexpected \(request.head.uri)"
                            )
                        )
                    )
                )
            },
            mapError: { _, _, _ in
                .response(
                    RuntimeResponse(
                        status: .internalServerError,
                        headers: HTTPHeaders(),
                        body: .buffer(
                            ByteBuffer(
                                string: "Mapped Error"
                            )
                        )
                    )
                )
            },
            notFound: Self.prepared(
                status: .notFound,
                body: "Not Found"
            ),
            payloadTooLarge: Self.prepared(
                status: .payloadTooLarge,
                body: "Payload Too Large"
            ),
            expectationFailed: Self.prepared(
                status: .expectationFailed,
                body: "Expectation Failed"
            ),
            internalServerError: Self.prepared(
                status: .internalServerError,
                body: "Internal Server Error"
            )
        )
    }

    private static func prepared(
        status: HTTPResponseStatus,
        body: String
    ) -> RuntimePreparedResponse {
        var buffer =
            ByteBufferAllocator().buffer(
                capacity: body.utf8.count
            )
        buffer.writeString(body)

        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: String(buffer.readableBytes)
        )

        return RuntimePreparedResponse(
            status: status,
            headers: headers,
            bodyBuffer: buffer
        )
    }
}

private final class LookupCounter:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock {
            count
        }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}
