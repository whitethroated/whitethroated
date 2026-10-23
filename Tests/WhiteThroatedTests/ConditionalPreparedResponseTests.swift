import XCTest
@testable import WhiteThroated
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

    func testKeepAliveUnconditionalFollowedByConditionalIsNotPoisoned()
        throws
    {
        let app = Application()
        let tag = EntityTag("status-v1")

        app.get(
            "/status",
            response: .text("ready"),
            etag: tag
        )

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try sendRequest(
            channel,
            makeHead(method: .GET)
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .ok(body: "ready")
        )

        // The second request must re-evaluate the header; the connection
        // cache from the first request may not pin its 200 decision.
        try sendRequest(
            channel,
            makeHead(
                method: .GET,
                ifNoneMatch: tag.headerValue
            )
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .notModified
        )

        try sendRequest(
            channel,
            makeHead(method: .GET)
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .ok(body: "ready")
        )

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
        _ = try channel.finish()
    }

    func testKeepAliveConditionalFollowedByUnconditionalIsNotPoisoned()
        throws
    {
        let app = Application()
        let tag = EntityTag("status-v1")

        app.get(
            "/status",
            response: .text("ready"),
            etag: tag
        )

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try sendRequest(
            channel,
            makeHead(
                method: .GET,
                ifNoneMatch: tag.headerValue
            )
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .notModified
        )

        // The cached 304 decision must not be served to a request
        // without the conditional header.
        try sendRequest(
            channel,
            makeHead(method: .GET)
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .ok(body: "ready")
        )

        try sendRequest(
            channel,
            makeHead(
                method: .GET,
                ifNoneMatch: tag.headerValue
            )
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .notModified
        )

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
        _ = try channel.finish()
    }

    func testKeepAliveConditionalMismatchServesFullBody() throws
    {
        let app = Application()
        let tag = EntityTag("status-v1")

        app.get(
            "/status",
            response: .text("ready"),
            etag: tag
        )

        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        try sendRequest(
            channel,
            makeHead(
                method: .GET,
                ifNoneMatch: tag.headerValue
            )
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .notModified
        )

        // A mismatching validator re-selects the full response.
        try sendRequest(
            channel,
            makeHead(
                method: .GET,
                ifNoneMatch: "\"status-v2\""
            )
        )
        XCTAssertEqual(
            try readOutcome(channel),
            .ok(body: "ready")
        )

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
        _ = try channel.finish()
    }

    private func sendRequest(
        _ channel: EmbeddedChannel,
        _ head: HTTPRequestHead
    ) throws {
        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }

    private enum TransportOutcome: Equatable {
        case ok(body: String)
        case notModified
    }

    private func readOutcome(
        _ channel: EmbeddedChannel
    ) throws -> TransportOutcome {
        guard
            case .head(let head)? =
                try channel.readOutbound(
                    as: HTTPServerResponsePart.self
                )
        else {
            XCTFail("Expected response head")
            return .notModified
        }

        switch head.status {
        case .notModified:
            guard
                case .end? =
                    try channel.readOutbound(
                        as: HTTPServerResponsePart.self
                    )
            else {
                XCTFail("Expected response end")
                return .notModified
            }

            return .notModified

        case .ok:
            guard
                case .body(let payload)? =
                    try channel.readOutbound(
                        as: HTTPServerResponsePart.self
                    ),
                case .byteBuffer(let buffer) =
                    payload
            else {
                XCTFail("Expected response body")
                return .ok(body: "")
            }
            guard
                case .end? =
                    try channel.readOutbound(
                        as: HTTPServerResponsePart.self
                    )
            else {
                XCTFail("Expected response end")
                return .ok(body: "")
            }

            return .ok(
                body: String(
                    decoding: buffer
                        .readableBytesView,
                    as: UTF8.self
                )
            )

        default:
            XCTFail("Unexpected status \(head.status)")
            return .ok(body: "")
        }
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
