import XCTest
@testable import WhiteThroated
import NIOCore

final class PipeliningAssistanceTests: XCTestCase {
    func testPreparedAndSynchronousRoutesDoNotRequireAssistance() {
        let app = Application()

        app.get(
            "/prepared",
            response: .text("ok")
        )
        app.get("/sync") { _ in
            .text("ok")
        }

        XCTAssertFalse(
            app.requiresPipeliningAssistance
        )
    }

    func testFutureRouteRequiresAssistance() {
        let app = Application()

        app.get("/future") { _, context in
            context.eventLoop.makeSucceededFuture(
                .text("ok")
            )
        }

        XCTAssertTrue(
            app.requiresPipeliningAssistance
        )
    }

    func testAsyncAwaitRouteRequiresAssistance() {
        let app = Application()

        app.get("/async") { _ async throws in
            .text("ok")
        }

        XCTAssertTrue(
            app.requiresPipeliningAssistance
        )
    }

    func testMiddlewareRequiresAssistance() {
        let app = Application()

        app.useFast { request, _, next in
            next(request)
        }

        XCTAssertTrue(
            app.requiresPipeliningAssistance
        )
    }
}
