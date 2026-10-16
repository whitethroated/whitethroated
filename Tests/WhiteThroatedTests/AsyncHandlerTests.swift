import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix

final class AsyncHandlerTests: XCTestCase {
    func testAsyncAwaitRouteReturnsFuturePath() throws {
        let app = Application()
        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: 1
        )
        defer {
            try? group.syncShutdownGracefully()
        }
        let loop = group.next()

        app.get("/async") { request async throws in
            .text("async:" + request.path)
        }

        let result = app.respondTransport(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/async"
            ),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .future(let future) = result else {
            return XCTFail(
                "Async route must use the future transport path"
            )
        }

        let response = try future.wait()

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "async:/async")
    }

    func testAsyncAwaitThrowFailsFuture() {
        enum TestError: Error {
            case failed
        }

        let app = Application()
        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: 1
        )
        defer {
            try? group.syncShutdownGracefully()
        }
        let loop = group.next()

        app.get("/async") { _ async throws -> Response in
            throw TestError.failed
        }

        let result = app.respondTransport(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/async"
            ),
            body: ByteBufferAllocator().buffer(capacity: 0),
            on: loop
        )

        guard case .future(let future) = result else {
            return XCTFail("Expected future response")
        }

        XCTAssertThrowsError(
            try future.wait()
        )
    }

    func testAsyncAwaitGroupRoute() throws {
        let app = Application()
        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: 1
        )
        defer {
            try? group.syncShutdownGracefully()
        }
        let loop = group.next()
        let api = app.group("/api")

        api.post("/jobs") { _ async throws in
            .text("queued")
        }

        let response = try app.respond(
            to: Request(
                head: HTTPRequestHead(
                    version: .http1_1,
                    method: .POST,
                    uri: "/api/jobs"
                ),
                body: ByteBufferAllocator().buffer(capacity: 0)
            ),
            on: loop
        ).wait()

        guard case .text(let body) = response.body else {
            return XCTFail("Expected text response")
        }

        XCTAssertEqual(body, "queued")
    }
}
