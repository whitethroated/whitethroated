import XCTest
@testable import WhiteThroated
import NIOEmbedded
import NIOHTTP1

final class PreparedBodylessStatusTests: XCTestCase {
    func testPreparedNoContentSuppressesCachedBody() throws {
        let app = Application()

        app.get(
            "/no-content",
            response: .text(
                "must-not-be-written",
                status: .noContent
            )
        )

        let parts = try responseParts(
            app: app,
            uri: "/no-content"
        )

        guard case .head(let head) = parts[0] else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.status,
            .noContent
        )
        XCTAssertNil(
            head.headers.first(
                name: "content-length"
            )
        )
        XCTAssertEqual(parts.count, 2)

        guard case .end = parts[1] else {
            return XCTFail("Expected response end")
        }
    }

    func testPreparedNotModifiedSuppressesBodyButKeepsRepresentationLength()
        throws
    {
        let app = Application()

        app.get(
            "/not-modified",
            response: .text(
                "hello",
                status: .notModified
            )
        )

        let parts = try responseParts(
            app: app,
            uri: "/not-modified"
        )

        guard case .head(let head) = parts[0] else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            head.status,
            .notModified
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "5"
        )
        XCTAssertEqual(parts.count, 2)

        guard case .end = parts[1] else {
            return XCTFail("Expected response end")
        }
    }

    private func responseParts(
        app: Application,
        uri: String
    ) throws -> [HTTPServerResponsePart] {
        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: uri
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        var result: [HTTPServerResponsePart] = []

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            result.append(part)
        }

        return result
    }
}
