import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class TransportFastPathTests: XCTestCase {
    func testPreparedRouteResolvesThroughPreparedPath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let result = app.respondTransport(
            head: makeHead(path: "/prepared"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .prepared(let prepared) = result else {
            return XCTFail(
                "Expected transport prepared fast path"
            )
        }

        XCTAssertEqual(
            prepared.http11Head.status,
            .ok
        )
    }

    func testSynchronousRouteUsesDirectSyncPath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        let result = app.respondTransport(
            head: makeHead(path: "/users/42"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Expected immediate synchronous response"
            )
        }

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "42")
    }

    func testAsynchronousRouteUsesDirectFuturePath() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get("/async") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("async")
            )
        }

        let result = app.respondTransport(
            head: makeHead(path: "/async"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .future = result else {
            return XCTFail(
                "Expected future asynchronous response"
            )
        }
    }

    func testMiddlewareDisablesDirectTransportDispatch() {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.useFast { _, _, _ in
            .response(
                .text(
                    "blocked",
                    status: .unauthorized
                )
            )
        }

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let result = app.respondTransport(
            head: makeHead(path: "/prepared"),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .immediate(let response) = result else {
            return XCTFail(
                "Middleware must participate in transport dispatch"
            )
        }

        XCTAssertEqual(
            response.status,
            .unauthorized
        )
    }

    func testBodylessPreparedRequestRespondsOnHead() throws {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                makeHead(path: "/prepared")
            )
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "prepared"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )

        _ = try channel.finish()
    }

    func testMixedCaseHostOnlyHTTP11PreparedRequestRespondsOnHead() throws {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = makeHead(
            path: "/prepared"
        )
        head.headers.add(
            name: "hOsT",
            value: "localhost"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "prepared"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testHostOnlyHTTP11PreparedRequestRespondsOnHead() throws {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = makeHead(path: "/prepared")
        head.headers.add(
            name: "host",
            value: "localhost"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "prepared"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testBodylessDynamicRequestRespondsOnHead() throws {
        let app = Application()

        app.get("/users/:id") { request in
            .text(request.parameter(at: 0) ?? "")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                makeHead(path: "/users/42")
            )
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "42"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        _ = try channel.finish()
    }

    func testConditionalPreparedRequestRespondsOnHead() throws {
        let app = Application()
        let tag = EntityTag("transport-v1")

        app.get(
            "/conditional",
            response: .text("cached"),
            etag: tag
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = makeHead(path: "/conditional")
        head.headers.add(
            name: "if-none-match",
            value: tag.headerValue
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected conditional response head"
            )
        }

        XCTAssertEqual(
            responseHead.status,
            .notModified
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected conditional response end"
            )
        }

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testNotFoundRequestRespondsOnHead() throws {
        let app = Application()

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                makeHead(path: "/missing")
            )
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected not-found response head"
            )
        }

        XCTAssertEqual(
            responseHead.status,
            .notFound
        )

        guard case .body? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected not-found response body"
            )
        }

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected not-found response end"
            )
        }

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testPreparedRouteWithDeclaredBodyWaitsForEnd() throws {
        let app = Application()

        app.post(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/prepared"
        )
        head.headers.add(
            name: "host",
            value: "localhost"
        )
        head.headers.add(
            name: "content-length",
            value: "1"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )

        var body = ByteBufferAllocator().buffer(
            capacity: 1
        )
        body.writeString("x")

        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(body)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "prepared"
        )

        _ = try channel.finish()
    }

    func testPreparedRouteWithExpectationDoesNotBypassExpectationHandling()
        throws
    {
        let app = Application()

        app.post(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/prepared"
        )
        head.headers.add(
            name: "expect",
            value: "something-else"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected expectation-failed response head"
            )
        }

        XCTAssertEqual(
            responseHead.status,
            .expectationFailed
        )

        _ = try? channel.finish()
    }

    func testDeclaredRequestBodyWaitsForEnd() throws {
        let app = Application()

        app.post("/echo") { request in
            .text(request.bodyString ?? "")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/echo"
        )
        head.headers.add(
            name: "content-length",
            value: "1"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )

        var body = ByteBufferAllocator().buffer(
            capacity: 1
        )
        body.writeString("x")

        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(body)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "x"
        )

        _ = try channel.finish()
    }

    func testHTTP11WithoutConnectionHeaderStaysKeepAlive() throws {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/prepared"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected HTTP/1.1 response head"
            )
        }

        XCTAssertNil(
            responseHead.headers.first(
                name: "connection"
            )
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testHTTP11ConnectionClosePreservesCloseSemantics() throws {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/prepared"
        )
        head.headers.add(
            name: "connection",
            value: "close"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected close response head"
            )
        }

        XCTAssertEqual(
            responseHead.headers.first(
                name: "connection"
            ),
            "close"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try? channel.finish()
    }

    func testHTTP10WithoutConnectionHeaderCloses() throws {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        let head = HTTPRequestHead(
            version: .http1_0,
            method: .GET,
            uri: "/prepared"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected HTTP/1.0 response head"
            )
        }

        XCTAssertEqual(
            responseHead.headers.first(
                name: "connection"
            ),
            "close"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try? channel.finish()
    }

    func testHTTP10KeepAliveHeaderPreservesKeepAlive() throws {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("prepared")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = HTTPRequestHead(
            version: .http1_0,
            method: .GET,
            uri: "/prepared"
        )
        head.headers.add(
            name: "connection",
            value: "keep-alive"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected HTTP/1.0 keep-alive response head"
            )
        }

        XCTAssertEqual(
            responseHead.headers.first(
                name: "connection"
            ),
            "keep-alive"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testFutureBodylessShortcutPreservesRemoteAddressContext() throws {
        let app = Application()

        app.get("/future-context") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text(
                    context.remoteAddress == nil
                        ? "missing"
                        : "present"
                )
            )
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                makeHead(
                    path: "/future-context"
                )
            )
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "present"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testFutureBodylessRouteDispatchesOnRequestHead() throws {
        let app = Application()

        app.get("/future") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("future")
            )
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                makeHead(path: "/future")
            )
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "future"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
        _ = try channel.finish()
    }

    func testFutureBodylessRouteWithDeclaredBodyDoesNotDispatchOnHead() throws {
        let app = Application()

        app.post("/future") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("future")
            )
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/future"
        )
        head.headers.add(
            name: "content-length",
            value: "1"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(
                ByteBuffer(string: "x")
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        XCTAssertEqual(
            try readResponseBody(channel),
            "future"
        )

        _ = try channel.finish()
    }

    func testMinimalHTTP11PreparedCacheHitInvalidatesOnMethodChange() throws {
        let app = Application()

        app.get(
            "/same",
            response: .text("get")
        )
        app.post(
            "/same",
            response: .text("post")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        for item in [
            (HTTPMethod.GET, "get"),
            (HTTPMethod.GET, "get"),
            (HTTPMethod.POST, "post"),
            (HTTPMethod.GET, "get")
        ] {
            var head = HTTPRequestHead(
                version: .http1_1,
                method: item.0,
                uri: "/same"
            )
            head.headers.add(
                name: "Host",
                value: "localhost"
            )

            _ = try channel.writeInbound(
                HTTPServerRequestPart.head(
                    head
                )
            )

            XCTAssertEqual(
                try readResponseBody(channel),
                item.1
            )

            _ = try channel.writeInbound(
                HTTPServerRequestPart.end(nil)
            )
        }

        _ = try channel.finish()
    }

    func testMinimalHTTP11PreparedCacheHitStillInvalidatesOnURIChange() throws {
        let app = Application()

        app.get(
            "/first",
            response: .text("first")
        )
        app.get(
            "/second",
            response: .text("second")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        for path in [
            "/first",
            "/first",
            "/second",
            "/first"
        ] {
            var head = makeHead(
                path: path
            )
            head.headers.add(
                name: "Host",
                value: "localhost"
            )

            _ = try channel.writeInbound(
                HTTPServerRequestPart.head(
                    head
                )
            )

            XCTAssertEqual(
                try readResponseBody(channel),
                path == "/second"
                    ? "second"
                    : "first"
            )

            _ = try channel.writeInbound(
                HTTPServerRequestPart.end(nil)
            )
        }

        _ = try channel.finish()
    }

    func testPreparedSideCacheDoesNotReuseDifferentURI() throws {
        let app = Application()

        app.get(
            "/first",
            response: .text("first")
        )
        app.get(
            "/second",
            response: .text("second")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        try writeRequest(
            path: "/first",
            channel: channel
        )
        XCTAssertEqual(
            try readResponseBody(channel),
            "first"
        )

        try writeRequest(
            path: "/first",
            channel: channel
        )
        XCTAssertEqual(
            try readResponseBody(channel),
            "first"
        )

        try writeRequest(
            path: "/second",
            channel: channel
        )
        XCTAssertEqual(
            try readResponseBody(channel),
            "second"
        )

        try writeRequest(
            path: "/first",
            channel: channel
        )
        XCTAssertEqual(
            try readResponseBody(channel),
            "first"
        )

        _ = try channel.finish()
    }

    func testConnectionRouteCacheDoesNotReuseDifferentURI() throws {
        let app = Application()

        app.get(
            "/first",
            response: .text("first")
        )
        app.get(
            "/second",
            response: .text("second")
        )

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        try writeRequest(
            path: "/first",
            channel: channel
        )
        XCTAssertEqual(
            try readResponseBody(channel),
            "first"
        )

        try writeRequest(
            path: "/first",
            channel: channel
        )
        XCTAssertEqual(
            try readResponseBody(channel),
            "first"
        )

        try writeRequest(
            path: "/second",
            channel: channel
        )
        XCTAssertEqual(
            try readResponseBody(channel),
            "second"
        )

        _ = try channel.finish()
    }

    private func writeRequest(
        path: String,
        channel: EmbeddedChannel
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                makeHead(path: path)
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }

    private func readResponseBody(
        _ channel: EmbeddedChannel
    ) throws -> String {
        guard case .head? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) else {
            return XCTFailAndReturn(
                "Expected response head"
            )
        }

        guard case .body(let body)? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) else {
            return XCTFailAndReturn(
                "Expected response body"
            )
        }

        guard case .byteBuffer(let buffer) = body else {
            return XCTFailAndReturn(
                "Expected byte-buffer body"
            )
        }

        guard case .end? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) else {
            return XCTFailAndReturn(
                "Expected response end"
            )
        }

        return buffer.getString(
            at: buffer.readerIndex,
            length: buffer.readableBytes
        ) ?? ""
    }

    private func XCTFailAndReturn(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        XCTFail(
            message,
            file: file,
            line: line
        )
        return ""
    }

    private func makeHead(path: String) -> HTTPRequestHead {
        HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: path
        )
    }
}
