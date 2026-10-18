import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ApplicationLifecycleTests: XCTestCase {
    func testTier1IsDefaultAndStockOverrideReachesRuntime() {
        let app = Application()
        XCTAssertTrue(app.configuration.useTier1HTTP1Experimental)
        XCTAssertTrue(app.makeRuntimeConfiguration().useTier1HTTP1)

        let stock = Application(configuration: ServerConfiguration(
            useTier1HTTP1Experimental: false
        ))
        XCTAssertFalse(stock.makeRuntimeConfiguration().useTier1HTTP1)
    }

    func testApplicationCanDispatchBeforeListening() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.get(
            "/health",
            response: .text("ok")
        )

        let response = try app.respond(
            to: Request(
                head: HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/health"
                ),
                body: ByteBufferAllocator().buffer(capacity: 0)
            ),
            on: loop
        ).wait()

        XCTAssertEqual(response.status, .ok)
    }

    func testApplicationErrorIsSendableError() {
        let error: any Error = ApplicationError.alreadyRunning

        XCTAssertTrue(error is ApplicationError)
    }
}
