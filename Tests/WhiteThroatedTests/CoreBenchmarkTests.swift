import Dispatch
import Foundation
import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class CoreBenchmarkTests: XCTestCase {
    func testCoreDispatchBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment

        try XCTSkipUnless(
            environment["WHITETHROATED_CORE_BENCHMARK"] == "1",
            "Set WHITETHROATED_CORE_BENCHMARK=1 to run core benchmarks."
        )

        let iterations = Int(
            environment["WHITETHROATED_CORE_ITERATIONS"] ?? "1000000"
        ) ?? 1_000_000

        precondition(iterations > 0)

        let app = Application()
        let loop = EmbeddedEventLoop()
        let emptyBody = ByteBufferAllocator().buffer(
            capacity: 0
        )

        app.get(
            "/prepared",
            response: .text("Hello, World!")
        )

        let conditionalTag =
            EntityTag("benchmark-v1")

        app.get(
            "/conditional-prepared",
            response: .text("Hello, World!"),
            etag: conditionalTag
        )

        app.get("/plaintext") { _ in
            .text("Hello, World!")
        }

        app.get("/future") { _, context in
            context.eventLoop.makeSucceededFuture(
                Response.text("Hello, World!")
            )
        }

        app.get("/users/:id") { request in
            .text(request.parameter("id") ?? "")
        }

        app.get("/query") { request in
            .text(request.query("q") ?? "")
        }

        app.post("/form") { request in
            .text(request.form("q") ?? "")
        }

        app.get("/cookie") { request in
            .text(
                request.cookie("session") ?? ""
            )
        }

        app.get("/method") { request in
            .text(
                request.method == .get
                    ? "GET"
                    : "OTHER"
            )
        }

        let cases = [
            BenchmarkCase(
                name: "prepared-exact",
                head: makeHead("/prepared")
            ),
            BenchmarkCase(
                name: "prepared-trie",
                head: makeHead("/prepared/")
            ),
            BenchmarkCase(
                name: "conditional-200",
                head: makeHead(
                    "/conditional-prepared"
                )
            ),
            BenchmarkCase(
                name: "conditional-304",
                head: makeHead(
                    "/conditional-prepared",
                    ifNoneMatch:
                        conditionalTag.headerValue
                )
            ),
            BenchmarkCase(
                name: "sync-static",
                head: makeHead("/plaintext")
            ),
            BenchmarkCase(
                name: "future-static",
                head: makeHead("/future")
            ),
            BenchmarkCase(
                name: "sync-param",
                head: makeHead("/users/42")
            ),
            BenchmarkCase(
                name: "sync-query",
                head: makeHead("/query?q=whitethroated")
            ),
            BenchmarkCase(
                name: "sync-cookie",
                head: makeHead(
                    "/cookie",
                    cookie:
                        "theme=dark; session=abc123; locale=en"
                )
            ),
            BenchmarkCase(
                name: "not-found",
                head: makeHead("/missing")
            ),
            BenchmarkCase(
                name: "sync-method",
                head: makeHead("/method")
            )
        ]

        print("")
        print(
            "WhiteThroated core dispatch benchmark "
            + "iterations=\(iterations)"
        )

        for benchmarkCase in cases {
            benchmark(
                benchmarkCase,
                iterations: iterations,
                app: app,
                eventLoop: loop,
                body: emptyBody
            )
        }

        print("")
    }

    func testRouterLookupBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment

        try XCTSkipUnless(
            environment["WHITETHROATED_ROUTER_CORE_BENCHMARK"] == "1",
            "Set WHITETHROATED_ROUTER_CORE_BENCHMARK=1 to run router lookup benchmarks."
        )

        let iterations = Int(
            environment["WHITETHROATED_ROUTER_CORE_ITERATIONS"]
                ?? "2000000"
        ) ?? 2_000_000

        precondition(iterations > 0)

        let router = Router()
        let prepared = PreparedResponse.text("ok")

        for index in 0..<4_096 {
            router.add(
                method: .get,
                path: "/static/r\(index)",
                preparedResponse: prepared
            )
        }

        router.add(
            method: .get,
            path: "/dynamic-control/:id",
            syncHandler: { _ in
                .text("ok")
            }
        )

        router.add(
            method: .put,
            path: "/dynamic-control/:id",
            syncHandler: { _ in
                .text("ok")
            }
        )

        let cases = [
            RouterBenchmarkCase(
                name: "exact-hit",
                method: NIOHTTP1.HTTPMethod.GET,
                uri: "/static/r4095"
            ),
            RouterBenchmarkCase(
                name: "dynamic-exact-miss",
                method: NIOHTTP1.HTTPMethod.GET,
                uri: "/dynamic-control/42"
            ),
            RouterBenchmarkCase(
                name: "dynamic-empty-exact",
                method: NIOHTTP1.HTTPMethod.PUT,
                uri: "/dynamic-control/42"
            ),
            RouterBenchmarkCase(
                name: "not-found-exact-miss",
                method: NIOHTTP1.HTTPMethod.GET,
                uri: "/missing/route"
            )
        ]

        print("")
        print(
            "WhiteThroated router lookup benchmark "
            + "iterations=\(iterations)"
        )

        for benchmarkCase in cases {
            benchmarkRouter(
                benchmarkCase,
                iterations: iterations,
                router: router
            )
        }

        print("")
    }

    func testMiddlewareScalingBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment

        try XCTSkipUnless(
            environment["WHITETHROATED_MIDDLEWARE_BENCHMARK"] == "1",
            "Set WHITETHROATED_MIDDLEWARE_BENCHMARK=1 to run middleware benchmarks."
        )

        let iterations = Int(
            environment["WHITETHROATED_MIDDLEWARE_ITERATIONS"]
                ?? "1000000"
        ) ?? 1_000_000

        precondition(iterations > 0)

        let loop = EmbeddedEventLoop()
        let emptyBody = ByteBufferAllocator().buffer(
            capacity: 0
        )
        let head = makeHead("/plaintext")

        print("")
        print(
            "WhiteThroated middleware scaling benchmark "
            + "iterations=\(iterations)"
        )

        let baseline = makeMiddlewareBenchmarkApp()

        benchmark(
            BenchmarkCase(
                name: "middleware-0",
                head: head
            ),
            iterations: iterations,
            app: baseline,
            eventLoop: loop,
            body: emptyBody
        )

        for layers in [1, 4, 8] {
            let app = makeMiddlewareBenchmarkApp(
                fastLayers: layers
            )

            benchmark(
                BenchmarkCase(
                    name: "fast-\(layers)",
                    head: head
                ),
                iterations: iterations,
                app: app,
                eventLoop: loop,
                body: emptyBody
            )
        }

        for layers in [1, 4, 8] {
            let app = makeMiddlewareBenchmarkApp(
                asynchronousLayers: layers
            )

            benchmark(
                BenchmarkCase(
                    name: "async-\(layers)",
                    head: head
                ),
                iterations: iterations,
                app: app,
                eventLoop: loop,
                body: emptyBody
            )
        }

        print("")
    }

    func testTransportWriterBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment

        try XCTSkipUnless(
            environment["WHITETHROATED_TRANSPORT_BENCHMARK"] == "1",
            "Set WHITETHROATED_TRANSPORT_BENCHMARK=1 to run transport benchmarks."
        )

        let iterations = Int(
            environment["WHITETHROATED_TRANSPORT_ITERATIONS"]
                ?? "100000"
        ) ?? 100_000

        precondition(iterations > 0)

        let preparedApp = Application()
        preparedApp.get(
            "/prepared",
            response: .text("Hello, World!")
        )

        let postStreamingApp = Application()
        postStreamingApp.get(
            "/prepared",
            response: .text("Hello, World!")
        )
        postStreamingApp.postStream(
            "/upload"
        ) { _, _ in
            BodyStreamConsumer(
                onChunk: { _ in },
                onEnd: {
                    .noContent()
                }
            )
        }

        let getStreamingApp = Application()
        getStreamingApp.get(
            "/prepared",
            response: .text("Hello, World!")
        )
        getStreamingApp.onStream(
            .get,
            "/stream"
        ) { _, _ in
            BodyStreamConsumer(
                onChunk: { _ in },
                onEnd: {
                    .noContent()
                }
            )
        }

        let syncApp = Application()
        syncApp.get("/plaintext") { _ in
            .text("Hello, World!")
        }

        let sharedTextBuffer: ByteBuffer = {
            var buffer =
                ByteBufferAllocator().buffer(
                    capacity: 13
                )
            buffer.writeString(
                "Hello, World!"
            )
            return buffer
        }()

        let syncBufferApp = Application()
        syncBufferApp.get("/buffer") { _ in
            Response
                .buffer(
                    sharedTextBuffer,
                    contentType:
                        "text/plain; charset=utf-8"
                )
        }

        let futureApp = Application()
        futureApp.get("/future") { _, context in
            context.eventLoop.makeSucceededFuture(
                Response.text("Hello, World!")
            )
        }

        let conditionalApp = Application()
        let conditionalTag =
            EntityTag("writer-v1")
        conditionalApp.get(
            "/conditional-prepared",
            response: .text("Hello, World!"),
            etag: conditionalTag
        )

        print("")
        print(
            "WhiteThroated transport writer benchmark "
            + "iterations=\(iterations)"
        )

        try benchmarkRawTransport(
            name: "raw-nio-writer",
            head: makeHead("/prepared"),
            expectedParts: 3,
            iterations: iterations
        )

        try benchmarkDirectPreparedTransport(
            name: "direct-prepared",
            app: preparedApp,
            head: makeHead("/prepared"),
            expectedParts: 3,
            iterations: iterations
        )

        try benchmarkTransport(
            name: "prepared-writer",
            app: preparedApp,
            head: makeHead("/prepared"),
            expectedParts: 3,
            iterations: iterations
        )

        try benchmarkTransport(
            name: "prepared-304-writer",
            app: conditionalApp,
            head: makeHead(
                "/conditional-prepared",
                ifNoneMatch:
                    conditionalTag.headerValue
            ),
            expectedParts: 2,
            iterations: iterations
        )

        try benchmarkTransport(
            name: "prepared-post-stream",
            app: postStreamingApp,
            head: makeHead("/prepared"),
            expectedParts: 3,
            iterations: iterations
        )

        try benchmarkTransport(
            name: "prepared-get-stream",
            app: getStreamingApp,
            head: makeHead("/prepared"),
            expectedParts: 3,
            iterations: iterations
        )

        try benchmarkTransport(
            name: "sync-writer",
            app: syncApp,
            head: makeHead("/plaintext"),
            expectedParts: 3,
            iterations: iterations
        )

        try benchmarkTransport(
            name: "sync-buffer-writer",
            app: syncBufferApp,
            head: makeHead("/buffer"),
            expectedParts: 3,
            iterations: iterations
        )

        try benchmarkTransport(
            name: "future-writer",
            app: futureApp,
            head: makeHead("/future"),
            expectedParts: 3,
            iterations: iterations
        )

        print("")
    }

    private func makeMiddlewareBenchmarkApp(
        fastLayers: Int = 0,
        asynchronousLayers: Int = 0
    ) -> Application {
        let app = Application()

        for _ in 0..<fastLayers {
            app.useFast { request, _, next in
                next(request)
            }
        }

        for _ in 0..<asynchronousLayers {
            app.use { request, _, next in
                next(request)
            }
        }

        app.get("/plaintext") { _ in
            .text("Hello, World!")
        }

        return app
    }

    private func benchmarkRouter(
        _ benchmarkCase: RouterBenchmarkCase,
        iterations: Int,
        router: Router
    ) {
        var checksum = 0

        for _ in 0..<20_000 {
            consumeRouterMatch(
                router.lookup(
                    method: benchmarkCase.method,
                    uri: benchmarkCase.uri.utf8
                ),
                checksum: &checksum
            )
        }

        let start = DispatchTime.now().uptimeNanoseconds

        for _ in 0..<iterations {
            consumeRouterMatch(
                router.lookup(
                    method: benchmarkCase.method,
                    uri: benchmarkCase.uri.utf8
                ),
                checksum: &checksum
            )
        }

        let end = DispatchTime.now().uptimeNanoseconds
        let elapsed = end - start
        let nanosecondsPerOperation =
            Double(elapsed) / Double(iterations)
        let operationsPerSecond =
            1_000_000_000 / nanosecondsPerOperation

        printBenchmarkLine(
            name: benchmarkCase.name,
            nanosecondsPerOperation:
                nanosecondsPerOperation,
            operationsPerSecond:
                operationsPerSecond,
            checksum: checksum
        )
    }

    @inline(never)
    private func consumeRouterMatch(
        _ result: RouterMatch,
        checksum: inout Int
    ) {
        switch result {
        case .prepared:
            checksum &+= 1

        case .conditionalPrepared:
            checksum &+= 7

        case .synchronous(
            _,
            let parameterNames,
            let parameterRanges
        ):
            checksum &+=
                parameterNames.count
                + parameterRanges.count
                + 2

        case .asynchronous:
            checksum &+= 3

        case .concurrent:
            checksum &+= 4

        case .streaming:
            checksum &+= 5

        case .notFound:
            checksum &+= 6
        }
    }

    private func benchmark(
        _ benchmarkCase: BenchmarkCase,
        iterations: Int,
        app: Application,
        eventLoop: EmbeddedEventLoop,
        body: ByteBuffer
    ) {
        var checksum = 0

        for _ in 0..<10_000 {
            consume(
                app.respondTransport(
                    head: benchmarkCase.head,
                    body: body,
                    on: eventLoop
                ),
                checksum: &checksum
            )
        }

        let start = DispatchTime.now().uptimeNanoseconds

        for _ in 0..<iterations {
            consume(
                app.respondTransport(
                    head: benchmarkCase.head,
                    body: body,
                    on: eventLoop
                ),
                checksum: &checksum
            )
        }

        let end = DispatchTime.now().uptimeNanoseconds
        let elapsed = end - start
        let nanosecondsPerOperation =
            Double(elapsed) / Double(iterations)
        let operationsPerSecond =
            1_000_000_000 / nanosecondsPerOperation

        printBenchmarkLine(
            name: benchmarkCase.name,
            nanosecondsPerOperation:
                nanosecondsPerOperation,
            operationsPerSecond:
                operationsPerSecond,
            checksum: checksum
        )
    }

    private func benchmarkRawTransport(
        name: String,
        head: HTTPRequestHead,
        expectedParts: Int,
        iterations: Int
    ) throws {
        let channel = EmbeddedChannel(
            handler: RawTransportBenchmarkHandler()
        )

        try benchmarkTransportChannel(
            name: name,
            channel: channel,
            head: head,
            expectedParts: expectedParts,
            iterations: iterations
        )
    }

    private func benchmarkDirectPreparedTransport(
        name: String,
        app: Application,
        head: HTTPRequestHead,
        expectedParts: Int,
        iterations: Int
    ) throws {
        let channel = EmbeddedChannel(
            handler: DirectPreparedTransportBenchmarkHandler(
                application: app
            )
        )

        try benchmarkTransportChannel(
            name: name,
            channel: channel,
            head: head,
            expectedParts: expectedParts,
            iterations: iterations
        )
    }

    private func benchmarkTransport(
        name: String,
        app: Application,
        head: HTTPRequestHead,
        expectedParts: Int,
        iterations: Int
    ) throws {
        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        try benchmarkTransportChannel(
            name: name,
            channel: channel,
            head: head,
            expectedParts: expectedParts,
            iterations: iterations
        )
    }

    private func benchmarkTransportChannel(
        name: String,
        channel: EmbeddedChannel,
        head: HTTPRequestHead,
        expectedParts: Int,
        iterations: Int
    ) throws {
        try channel.connect(
            to: SocketAddress(
                ipAddress: "127.0.0.1",
                port: 1
            )
        ).wait()

        var checksum = 0

        for _ in 0..<1_000 {
            try writeAndDrain(
                head: head,
                expectedParts: expectedParts,
                channel: channel,
                checksum: &checksum
            )
        }

        let start = DispatchTime.now().uptimeNanoseconds

        for _ in 0..<iterations {
            try writeAndDrain(
                head: head,
                expectedParts: expectedParts,
                channel: channel,
                checksum: &checksum
            )
        }

        let end = DispatchTime.now().uptimeNanoseconds
        let elapsed = end - start
        let nanosecondsPerOperation =
            Double(elapsed) / Double(iterations)
        let operationsPerSecond =
            1_000_000_000 / nanosecondsPerOperation

        printBenchmarkLine(
            name: name,
            nanosecondsPerOperation:
                nanosecondsPerOperation,
            operationsPerSecond:
                operationsPerSecond,
            checksum: checksum
        )

        _ = try channel.finish()
    }

    @inline(__always)
    private func writeAndDrain(
        head: HTTPRequestHead,
        expectedParts: Int,
        channel: EmbeddedChannel,
        checksum: inout Int
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        for _ in 0..<expectedParts {
            guard let part = try channel.readOutbound(
                as: HTTPServerResponsePart.self
            ) else {
                preconditionFailure(
                    "Expected \(expectedParts) outbound response parts"
                )
            }

            switch part {
            case .head(let responseHead):
                checksum &+= Int(
                    responseHead.status.code
                )

            case .body:
                checksum &+= 1

            case .end:
                checksum &+= 1
            }
        }
    }

    @inline(never)
    private func consume(
        _ result: ResponderResult,
        checksum: inout Int
    ) {
        switch result {
        case .prepared(let prepared):
            checksum &+= Int(
                prepared.http11Head.status.code
            )

        case .immediate(let response):
            checksum &+= Int(response.status.code)

            switch response.body {
            case .empty:
                break
            case .text(let value):
                checksum &+= value.utf8.count
            case .bytes(let value):
                checksum &+= value.count
            case .buffer(let value):
                checksum &+= value.readableBytes
            case .fileRegion(let value):
                checksum &+= value.readableBytes
            case .stream:
                checksum &+= 1
            }

        case .streaming:
            checksum &+= 1

        case .future:
            checksum &+= 1
        }
    }

    private func printBenchmarkLine(
        name: String,
        nanosecondsPerOperation: Double,
        operationsPerSecond: Double,
        checksum: Int
    ) {
        let paddedName = name.padding(
            toLength: 20,
            withPad: " ",
            startingAt: 0
        )
        let nsText = String(
            format: "%.2f",
            nanosecondsPerOperation
        )
        let opsText = String(
            format: "%.0f",
            operationsPerSecond
        )

        print(
            "\(paddedName) "
            + "\(nsText) ns/op "
            + "\(opsText) ops/s "
            + "checksum=\(checksum)"
        )
    }

    private func makeHead(
        _ uri: String,
        ifNoneMatch: String? = nil,
        cookie: String? = nil
    ) -> HTTPRequestHead {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: uri
        )

        if let ifNoneMatch {
            head.headers.add(
                name: "if-none-match",
                value: ifNoneMatch
            )
        }

        if let cookie {
            head.headers.add(
                name: "cookie",
                value: cookie
            )
        }

        return head
    }
}

private struct BenchmarkCase {
    let name: String
    let head: HTTPRequestHead
}

private struct RouterBenchmarkCase {
    let name: String
    let method: NIOHTTP1.HTTPMethod
    let uri: String
}

private final class DirectPreparedTransportBenchmarkHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let application: Application
    private var requestHead: HTTPRequestHead?

    init(application: Application) {
        self.application = application
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head

        case .body:
            break

        case .end:
            guard let head = requestHead else {
                return
            }

            guard case .prepared(let storage) =
                application.lookupTransport(
                    head: head
                )
            else {
                preconditionFailure(
                    "Direct prepared benchmark expected prepared route"
                )
            }

            context.write(
                wrapOutboundOut(
                    .head(storage.http11Head)
                ),
                promise: nil
            )

            if let body = storage.bodyBuffer {
                context.write(
                    wrapOutboundOut(
                        .body(.byteBuffer(body))
                    ),
                    promise: nil
                )
            }

            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )

            requestHead = nil
        }
    }
}

private final class RawTransportBenchmarkHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let responseHead: HTTPResponseHead
    private let body: ByteBuffer

    init() {
        var body = ByteBufferAllocator().buffer(
            capacity: 13
        )
        body.writeString("Hello, World!")
        self.body = body

        var headers = HTTPHeaders()
        headers.add(
            name: "content-type",
            value: "text/plain; charset=utf-8"
        )
        headers.add(
            name: "content-length",
            value: "13"
        )

        self.responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: headers
        )
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        switch unwrapInboundIn(data) {
        case .head, .body:
            break

        case .end:
            context.write(
                wrapOutboundOut(
                    .head(responseHead)
                ),
                promise: nil
            )
            context.write(
                wrapOutboundOut(
                    .body(
                        .byteBuffer(body)
                    )
                ),
                promise: nil
            )
            context.writeAndFlush(
                wrapOutboundOut(.end(nil)),
                promise: nil
            )
        }
    }
}
