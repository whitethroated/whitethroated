import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class PreparedNotFoundTests: XCTestCase {
    func testTransportNotFoundUsesPreparedStorage() {
        let app = Application()
        let result = app.respondTransport(
            head: HTTPRequestHead(
                version: .http1_1,
                method: .GET,
                uri: "/missing"
            ),
            body: ByteBufferAllocator()
                .buffer(capacity: 0),
            on: EmbeddedEventLoop()
        )

        guard case .prepared(let storage) =
            result
        else {
            return XCTFail(
                "Expected prepared 404 fast path"
            )
        }

        XCTAssertEqual(
            storage.http11Head.status,
            .notFound
        )
        XCTAssertEqual(
            storage.http11Head.headers.first(
                name: "content-length"
            ),
            "9"
        )
    }

    func testPreparedNotFoundConvenience() {
        let prepared =
            PreparedResponse.notFound()

        XCTAssertEqual(
            prepared.http11Head.status,
            .notFound
        )

        guard let body =
            prepared.bodyBuffer
        else {
            return XCTFail(
                "Expected prepared body"
            )
        }

        XCTAssertEqual(
            body.getString(
                at: body.readerIndex,
                length: body.readableBytes
            ),
            "Not Found"
        )
    }

    func testMissingRouteWritesExpectedPreparedResponse()
        throws
    {
        let app = Application()
        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(
                application: app
            )
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(
                HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/missing"
                )
            )
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let head)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response head"
            )
        }

        XCTAssertEqual(
            head.status,
            .notFound
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "9"
        )

        guard case .body(
            .byteBuffer(let body)
        )? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        )
        else {
            return XCTFail(
                "Expected response body"
            )
        }

        XCTAssertEqual(
            body.getString(
                at: body.readerIndex,
                length: body.readableBytes
            ),
            "Not Found"
        )
    }
}
