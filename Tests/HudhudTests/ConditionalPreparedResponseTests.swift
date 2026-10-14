import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ConditionalPreparedResponseTests: XCTestCase {
    func testConditionalPreparedReturnsCached200WithoutMatch()
        throws
    {
        let app = Application()
        let tag = EntityTag("status-v1")

        app.get(
            "/status",
            response:
                PreparedResponse
                    .text("ready")
                    .header(
                        "cache-control",
                        "public, max-age=60"
                    ),
            etag: tag
        )

        let result = app.respondTransport(
            head: makeHead(
                method: .GET
            ),
            body: emptyBody(),
            on: EmbeddedEventLoop()
        )

        guard case .prepared(let storage) =
            result
        else {
            return XCTFail(
                "Expected prepared fast path"
            )
        }

        XCTAssertEqual(
            storage.http11Head.status,
            .ok
        )
        XCTAssertEqual(
            storage.http11Head.headers.first(
                name: "etag"
            ),
            tag.headerValue
        )
        XCTAssertNotNil(storage.bodyBuffer)
    }

    func testConditionalPreparedReturnsCached304OnMatch()
        throws
    {
        let app = Application()
        let tag = EntityTag("status-v1")

        app.get(
            "/status",
            response:
                PreparedResponse
                    .text("ready")
                    .header(
                        "cache-control",
                        "public, max-age=60"
                    ),
            etag: tag
        )

        let result = app.respondTransport(
            head: makeHead(
                method: .GET,
                ifNoneMatch: tag.headerValue
            ),
            body: emptyBody(),
            on: EmbeddedEventLoop()
        )

        guard case .prepared(let storage) =
            result
        else {
            return XCTFail(
                "Expected prepared fast path"
            )
        }

        XCTAssertEqual(
            storage.http11Head.status,
            .notModified
        )
        XCTAssertEqual(
            storage.http11Head.headers.first(
                name: "etag"
            ),
            tag.headerValue
        )
        XCTAssertEqual(
            storage.http11Head.headers.first(
                name: "cache-control"
            ),
            "public, max-age=60"
        )
        XCTAssertEqual(
            storage.http11Head.headers.first(
                name: "content-length"
            ),
            "5"
        )
        XCTAssertNil(storage.bodyBuffer)
    }

    func testConditionalPreparedHeadFallbackWritesNoBody()
        throws
    {
        let app = Application()
        let tag = EntityTag("status-v1")

        app.get(
            "/status",
            response:
                PreparedResponse.text("ready"),
            etag: tag
        )

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        let head = makeHead(
            method: .HEAD,
            ifNoneMatch: tag.headerValue
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
                name: "content-length"
            ),
            "5"
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

    func testConditionalPreparedWorksThroughRouteGroup()
        throws
    {
        let app = Application()
        let api = app.group("/api")
        let tag = EntityTag("group-v1")

        api.get(
            "/status",
            response: .text("ok"),
            etag: tag
        )

        let result = app.respondTransport(
            head: makeHead(
                method: .GET,
                uri: "/api/status",
                ifNoneMatch: tag.headerValue
            ),
            body: emptyBody(),
            on: EmbeddedEventLoop()
        )

        guard case .prepared(let storage) =
            result
        else {
            return XCTFail(
                "Expected prepared fast path"
            )
        }

        XCTAssertEqual(
            storage.http11Head.status,
            .notModified
        )
    }

    private func makeHead(
        method: NIOHTTP1.HTTPMethod,
        uri: String = "/status",
        ifNoneMatch: String? = nil
    ) -> HTTPRequestHead {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: uri
        )

        if let ifNoneMatch {
            head.headers.add(
                name: "if-none-match",
                value: ifNoneMatch
            )
        }

        return head
    }

    private func emptyBody() -> ByteBuffer {
        ByteBufferAllocator()
            .buffer(capacity: 0)
    }
}
