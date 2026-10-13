import XCTest
@testable import Hudhud
import NIOEmbedded
import NIOHTTP1

final class HTTPServerHandlerTests: XCTestCase {
    func testHeadResponseSuppressesBody() throws {
        let app = Application()

        app.get("/resource") { _ in
            .text("payload")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        var requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .HEAD,
            uri: "/resource"
        )
        requestHead.headers.add(
            name: "connection",
            value: "close"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(requestHead)
        )
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            responseHead.headers.first(name: "content-length"),
            "7"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "HEAD response must not emit a body part"
            )
        }
    }

    func testHTTP11KeepAliveDoesNotAddRedundantConnectionHeader() throws {
        let app = Application()

        app.get("/") { _ in
            .text("ok")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(requestHead)
        )
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertNil(
            responseHead.headers.first(name: "connection")
        )
        XCTAssertEqual(
            responseHead.version,
            .http1_1
        )
    }

    func testHTTP10KeepAliveIsEchoed() throws {
        let app = Application()

        app.get("/") { _ in
            .text("ok")
        }

        let channel = EmbeddedChannel(
            handler: HTTPServerHandler(application: app)
        )

        var requestHead = HTTPRequestHead(
            version: .http1_0,
            method: .GET,
            uri: "/"
        )
        requestHead.headers.add(
            name: "connection",
            value: "keep-alive"
        )

        try channel.writeInbound(
            HTTPServerRequestPart.head(requestHead)
        )
        try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        guard case .head(let responseHead)? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail("Expected response head")
        }

        XCTAssertEqual(
            responseHead.headers.first(name: "connection"),
            "keep-alive"
        )
        XCTAssertEqual(
            responseHead.version,
            .http1_0
        )
    }
}
