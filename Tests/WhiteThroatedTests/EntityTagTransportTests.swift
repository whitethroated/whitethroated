import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class EntityTagTransportTests: XCTestCase {
    func testIfNoneMatchProducesBodyless304() throws {
        let app = Application()
        let tag = EntityTag("article-v42")

        app.get("/article") { request in
            if request.matchesIfNoneMatch(tag) {
                return .notModified(
                    etag: tag
                )
            }

            return Response
                .text("large body")
                .etag(tag)
        }

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/article"
        )
        head.headers.add(
            name: "if-none-match",
            value: tag.headerValue
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response head"
            )
        }

        XCTAssertEqual(
            responseHead.status,
            .notModified
        )
        XCTAssertEqual(
            responseHead.headers.first(
                name: "etag"
            ),
            tag.headerValue
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response end"
            )
        }

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
    }
}
