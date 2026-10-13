import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ApplicationLifecycleTests: XCTestCase {
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
