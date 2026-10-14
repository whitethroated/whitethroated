import XCTest
@testable import Hudhud
import NIOCore
import NIOHTTP1

private final class MultipartCollector {
    struct Part {
        var name: String
        var filename: String?
        var contentType: String?
        var bytes: [UInt8]
    }

    var parts: [Part] = []

    func receive(
        _ event: MultipartFormDataEvent
    ) {
        switch event {
        case .partBegin(let part):
            parts.append(
                Part(
                    name: part.name,
                    filename: part.filename,
                    contentType:
                        part.contentType,
                    bytes: []
                )
            )

        case .partBody(let buffer):
            parts[
                parts.index(before: parts.endIndex)
            ].bytes.append(
                contentsOf:
                    buffer.readableBytesView
            )

        case .partEnd:
            break
        }
    }
}

final class MultipartFormDataTests: XCTestCase {
    func testBoundaryParsingSupportsQuotedValue() throws {
        XCTAssertEqual(
            try MultipartFormDataParser.boundary(
                from:
                    "multipart/form-data; boundary=\"abc-123\""
            ),
            "abc-123"
        )
    }

    func testBoundaryParsingRejectsWrongMediaType() {
        XCTAssertThrowsError(
            try MultipartFormDataParser.boundary(
                from: "application/json"
            )
        ) { error in
            XCTAssertEqual(
                error as? MultipartFormDataError,
                .invalidContentType
            )
        }
    }

    func testParsesTextAndFilePartsAcrossSingleByteChunks() throws {
        let boundary = "AaB03x"
        let body =
            "--AaB03x\r\n"
            + "Content-Disposition: form-data; name=\"title\"\r\n"
            + "\r\n"
            + "Hudhud\r\n"
            + "--AaB03x\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\n"
            + "Content-Type: text/plain\r\n"
            + "\r\n"
            + "hello file\r\n"
            + "--AaB03x--\r\n"

        let parser = try MultipartFormDataParser(
            boundary: boundary
        )
        let collector = MultipartCollector()

        for byte in body.utf8 {
            var chunk = ByteBufferAllocator()
                .buffer(capacity: 1)
            chunk.writeInteger(byte)

            try parser.receive(
                chunk,
                onEvent: collector.receive
            )
        }

        try parser.finish(
            onEvent: collector.receive
        )

        XCTAssertTrue(parser.isFinished)
        XCTAssertEqual(
            collector.parts.count,
            2
        )
        XCTAssertEqual(
            collector.parts[0].name,
            "title"
        )
        XCTAssertNil(
            collector.parts[0].filename
        )
        XCTAssertEqual(
            String(
                decoding: collector.parts[0].bytes,
                as: UTF8.self
            ),
            "Hudhud"
        )
        XCTAssertEqual(
            collector.parts[1].name,
            "file"
        )
        XCTAssertEqual(
            collector.parts[1].filename,
            "hello.txt"
        )
        XCTAssertEqual(
            collector.parts[1].contentType,
            "text/plain"
        )
        XCTAssertEqual(
            String(
                decoding: collector.parts[1].bytes,
                as: UTF8.self
            ),
            "hello file"
        )
    }

    func testFalseBoundaryPrefixRemainsPartBody() throws {
        let boundary = "boundary"
        let payload =
            "before\r\n--boundaryXafter"
        let body =
            "--boundary\r\n"
            + "Content-Disposition: form-data; name=\"data\"\r\n"
            + "\r\n"
            + payload
            + "\r\n--boundary--\r\n"

        let parser = try MultipartFormDataParser(
            boundary: boundary
        )
        let collector = MultipartCollector()

        var chunk = ByteBufferAllocator()
            .buffer(capacity: body.utf8.count)
        chunk.writeString(body)

        try parser.receive(
            chunk,
            onEvent: collector.receive
        )
        try parser.finish(
            onEvent: collector.receive
        )

        XCTAssertEqual(
            String(
                decoding: collector.parts[0].bytes,
                as: UTF8.self
            ),
            payload
        )
    }

    func testBinaryPartPreservesNullAndCRLFBytes() throws {
        let boundary = "binary"
        let prefix =
            "--binary\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"x.bin\"\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "\r\n"
        let suffix = "\r\n--binary--\r\n"
        let binary: [UInt8] = [
            0,
            1,
            2,
            13,
            10,
            3,
            255
        ]

        var body = ByteBufferAllocator()
            .buffer(
                capacity:
                    prefix.utf8.count
                    + binary.count
                    + suffix.utf8.count
            )
        body.writeString(prefix)
        body.writeBytes(binary)
        body.writeString(suffix)

        let parser = try MultipartFormDataParser(
            boundary: boundary
        )
        let collector = MultipartCollector()

        try parser.receive(
            body,
            onEvent: collector.receive
        )
        try parser.finish(
            onEvent: collector.receive
        )

        XCTAssertEqual(
            collector.parts[0].bytes,
            binary
        )
    }

    func testEmptyPartBodyIsSupported() throws {
        let body =
            "--empty\r\n"
            + "Content-Disposition: form-data; name=\"value\"\r\n"
            + "\r\n"
            + "\r\n--empty--\r\n"

        let parser = try MultipartFormDataParser(
            boundary: "empty"
        )
        let collector = MultipartCollector()
        var chunk = ByteBufferAllocator()
            .buffer(capacity: body.utf8.count)
        chunk.writeString(body)

        try parser.receive(
            chunk,
            onEvent: collector.receive
        )
        try parser.finish(
            onEvent: collector.receive
        )

        XCTAssertEqual(
            collector.parts[0].bytes,
            []
        )
    }

    func testHeaderLimitRejectsOversizedPartHeaders() throws {
        let limits = MultipartFormDataLimits(
            maxParts: 2,
            maxHeadersPerPart: 4,
            maxHeaderBytesPerPart: 16
        )
        let parser = try MultipartFormDataParser(
            boundary: "limit",
            limits: limits
        )
        let body =
            "--limit\r\n"
            + "Content-Disposition: form-data; name=\"x\"\r\n"
            + "\r\nvalue\r\n"
            + "--limit--\r\n"

        var chunk = ByteBufferAllocator()
            .buffer(capacity: body.utf8.count)
        chunk.writeString(body)

        XCTAssertThrowsError(
            try parser.receive(
                chunk,
                onEvent: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? MultipartFormDataError,
                .headerBlockTooLarge(limit: 16)
            )
        }
    }

    func testPartLimitRejectsExcessParts() throws {
        let limits = MultipartFormDataLimits(
            maxParts: 1
        )
        let parser = try MultipartFormDataParser(
            boundary: "parts",
            limits: limits
        )
        let body =
            "--parts\r\n"
            + "Content-Disposition: form-data; name=\"a\"\r\n\r\n"
            + "1\r\n"
            + "--parts\r\n"
            + "Content-Disposition: form-data; name=\"b\"\r\n\r\n"
            + "2\r\n"
            + "--parts--\r\n"

        var chunk = ByteBufferAllocator()
            .buffer(capacity: body.utf8.count)
        chunk.writeString(body)

        XCTAssertThrowsError(
            try parser.receive(
                chunk,
                onEvent: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? MultipartFormDataError,
                .tooManyParts(limit: 1)
            )
        }
    }

    func testFinishRejectsMissingClosingBoundary() throws {
        let parser = try MultipartFormDataParser(
            boundary: "missing"
        )
        let body =
            "--missing\r\n"
            + "Content-Disposition: form-data; name=\"a\"\r\n\r\n"
            + "value"

        var chunk = ByteBufferAllocator()
            .buffer(capacity: body.utf8.count)
        chunk.writeString(body)

        try parser.receive(
            chunk,
            onEvent: { _ in }
        )

        XCTAssertThrowsError(
            try parser.finish()
        ) { error in
            XCTAssertEqual(
                error as? MultipartFormDataError,
                .unexpectedEnd
            )
        }
    }

    func testStreamRequestInitializerReadsContentTypeBoundary() throws {
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/upload"
        )
        head.headers.add(
            name: "content-type",
            value:
                "multipart/form-data; boundary=request-boundary"
        )

        let request = Request(
            head: head,
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )
        let parser = try MultipartFormDataParser(
            request: StreamRequest(request)
        )

        XCTAssertFalse(parser.isFinished)
    }
}
