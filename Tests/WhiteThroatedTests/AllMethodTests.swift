import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class AllMethodTests: XCTestCase {
    func testPreparedAllRegistersAcrossCommonMethods() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()

        app.all(
            "/health",
            response: .text("ok")
        )

        for method in [
            NIOHTTP1.HTTPMethod.GET,
            .POST,
            .PUT,
            .PATCH,
            .DELETE,
            .HEAD,
            .OPTIONS,
            .CONNECT,
            .TRACE
        ] {
            let response = try app.respond(
                to: makeRequest(
                    path: "/health",
                    method: method
                ),
                on: loop
            ).wait()

            XCTAssertEqual(
                response.status,
                .ok,
                "Failed for \(method)"
            )
        }
    }

    func testGroupAllUsesGroupPrefix() throws {
        let app = Application()
        let loop = EmbeddedEventLoop()
        let api = app.group("/api")

        api.all("/status") { _ in
            .text("ok")
        }

        for method in [
            NIOHTTP1.HTTPMethod.GET,
            .POST,
            .PATCH
        ] {
            let response = try app.respond(
                to: makeRequest(
                    path: "/api/status",
                    method: method
                ),
                on: loop
            ).wait()

            guard case .text(let body) = response.body else {
                return XCTFail("Expected text response")
            }

            XCTAssertEqual(body, "ok")
        }
    }

    private func makeRequest(
        path: String,
        method: NIOHTTP1.HTTPMethod
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: path
            ),
            body: ByteBufferAllocator().buffer(capacity: 0)
        )
    }
}
