import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

final class ByteRangeTransportTests: XCTestCase {
    func testGetPartialFileRegionWrites206AndSlicedRegion() throws {
        let handle = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: -1
        )
        let source = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 1_000
        )
        let app = makeApp(
            region: source
        )
        let channel = try makeChannel(app)

        try sendRequest(
            method: .GET,
            range: "bytes=100-199",
            channel: channel
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
            .partialContent
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-range"
            ),
            "bytes 100-199/1000"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "100"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "accept-ranges"
            ),
            "bytes"
        )

        guard case .body(
            .fileRegion(let region)
        )? = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        )
        else {
            return XCTFail(
                "Expected FileRegion body"
            )
        }

        XCTAssertEqual(
            region.readerIndex,
            100
        )
        XCTAssertEqual(
            region.endIndex,
            200
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

    func testHeadPartialFileRegionPreservesLengthAndSuppressesBody()
        throws
    {
        let handle = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: -1
        )
        let source = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 1_000
        )
        let app = makeApp(
            region: source
        )
        let channel = try makeChannel(app)

        try sendRequest(
            method: .HEAD,
            range: "bytes=100-199",
            channel: channel
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
            .partialContent
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "100"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-range"
            ),
            "bytes 100-199/1000"
        )

        guard case .end? =
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        else {
            return XCTFail(
                "Expected response end without body"
            )
        }

        XCTAssertNil(
            try channel.readOutbound(
                as: HTTPServerResponsePart.self
            )
        )
    }

    func testUnsatisfiableRangeWrites416Metadata() throws {
        let handle = NIOFileHandle(
            _deprecatedTakingOwnershipOfDescriptor: -1
        )
        let source = FileRegion(
            fileHandle: handle,
            readerIndex: 0,
            endIndex: 1_000
        )
        let app = makeApp(
            region: source
        )
        let channel = try makeChannel(app)

        try sendRequest(
            method: .GET,
            range: "bytes=1000-",
            channel: channel
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
            .rangeNotSatisfiable
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-range"
            ),
            "bytes */1000"
        )
        XCTAssertEqual(
            head.headers.first(
                name: "content-length"
            ),
            "0"
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

    private func makeApp(
        region: FileRegion
    ) -> Application {
        let app = Application()

        app.get("/file") { request in
            switch request.byteRange(
                totalLength: region.readableBytes
            ) {
            case .satisfiable(let range):
                return .partialFileRegion(
                    region,
                    range: range,
                    contentType:
                        "application/octet-stream"
                )

            case .unsatisfiable:
                return .rangeNotSatisfiable(
                    totalLength:
                        region.readableBytes
                )

            case .none,
                 .malformed,
                 .unsupportedMultiple,
                 .unsupportedUnit:
                return Response
                    .fileRegion(
                        region,
                        contentType:
                            "application/octet-stream"
                    )
                    .acceptingByteRanges()
            }
        }

        return app
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

    private func sendRequest(
        method: NIOHTTP1.HTTPMethod,
        range: String,
        channel: EmbeddedChannel
    ) throws {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: method,
            uri: "/file"
        )
        head.headers.add(
            name: "range",
            value: range
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )
    }
}
