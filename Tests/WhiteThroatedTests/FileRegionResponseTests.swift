import Foundation
import XCTest
@testable import WhiteThroated
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class FileRegionResponseTests: XCTestCase {
    func testFileRegionResponseWritesIODataWithoutByteBufferCopy() throws {
        try withTemporaryRegion { region in
            let app = Application()

            app.get("/file") { _ in
                .fileRegion(
                    region,
                    contentType: "text/plain"
                )
            }

            let channel = try makeChannel(app)

            _ = try channel.writeInbound(
                HTTPServerRequestPart.head(
                    makeHead(
                        method: .GET
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
                head.headers.first(
                    name: "content-length"
                ),
                "5"
            )
            XCTAssertEqual(
                head.headers.first(
                    name: "content-type"
                ),
                "text/plain"
            )

            guard case .body(let data)? =
                try channel.readOutbound(
                    as: HTTPServerResponsePart.self
                )
            else {
                return XCTFail(
                    "Expected file-region body"
                )
            }

            guard case .fileRegion(let writtenRegion) = data else {
                return XCTFail(
                    "Expected IOData.fileRegion"
                )
            }

            XCTAssertEqual(
                writtenRegion.readableBytes,
                5
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
        }
    }

    func testHeadFileRegionPreservesLengthWithoutBody() throws {
        try withTemporaryRegion { region in
            let app = Application()

            app.get("/file") { _ in
                .fileRegion(region)
            }

            let channel = try makeChannel(app)

            _ = try channel.writeInbound(
                HTTPServerRequestPart.head(
                    makeHead(
                        method: .HEAD
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
                head.headers.first(
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
                    "HEAD must suppress file-region body"
                )
            }
        }
    }

    private func withTemporaryRegion(
        _ operation: (FileRegion) throws -> Void
    ) throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString
            )

        try Data("hello".utf8).write(
            to: url
        )

        let handle = try NIOFileHandle(
            _deprecatedPath: url.path
        )

        defer {
            try? handle.close()
            try? FileManager.default
                .removeItem(at: url)
        }

        let region = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 5
        )

        try operation(region)
    }

    private func makeChannel(
        _ app: Application
    ) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()

        try channel.pipeline.syncOperations
            .addHandler(
                HTTPServerHandler(
                    application: app
                )
            )

        return channel
    }

    private func makeHead(
        method: NIOHTTP1.HTTPMethod
    ) -> HTTPRequestHead {
        HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: "/file"
        )
    }
}
