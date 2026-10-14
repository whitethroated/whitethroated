import XCTest
@testable import Hudhud
import NIOCore
import NIOEmbedded
import NIOHTTP1

private final class MultipartUploadState:
    @unchecked Sendable
{
    var fieldValue = ""
    var filename: String?
    var fileBytes = 0
    var activeName: String?
}

final class MultipartStreamingIntegrationTests:
    XCTestCase
{
    func testMultipartParserRunsInsideStreamingRoute() throws {
        let app = Application()
        let state = MultipartUploadState()

        app.postStream(
            "/upload",
            maxBodyBytes: 1024 * 1024
        ) { request, _ in
            let parser: MultipartFormDataParser

            do {
                parser = try MultipartFormDataParser(
                    request: request
                )
            } catch {
                return BodyStreamConsumer(
                    onChunk: { _ in },
                    onEnd: {
                        .text(
                            "invalid multipart",
                            status: .badRequest
                        )
                    }
                )
            }

            return BodyStreamConsumer(
                onChunkThrowing: { chunk in
                    try parser.receive(
                        chunk
                    ) { event in
                        switch event {
                        case .partBegin(let part):
                            state.activeName =
                                part.name

                            if part.name == "file" {
                                state.filename =
                                    part.filename
                            }

                        case .partBody(let body):
                            if
                                state.activeName
                                == "title"
                            {
                                state.fieldValue +=
                                    body.getString(
                                        at:
                                            body.readerIndex,
                                        length:
                                            body
                                                .readableBytes
                                    ) ?? ""
                            } else if
                                state.activeName
                                == "file"
                            {
                                state.fileBytes +=
                                    body.readableBytes
                            }

                        case .partEnd:
                            state.activeName = nil
                        }
                    }
                },
                onEnd: {
                    do {
                        try parser.finish()

                        return .text(
                            [
                                state.fieldValue,
                                state.filename ?? "",
                                String(state.fileBytes)
                            ].joined(separator: ":")
                        )
                    } catch {
                        return .text(
                            "invalid multipart",
                            status: .badRequest
                        )
                    }
                }
            )
        }

        let channel = try makeChannel(app)
        let boundary = "integration-boundary"
        let body =
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"title\"\r\n"
            + "\r\n"
            + "Hudhud\r\n"
            + "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"demo.bin\"\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "\r\n"
            + "1234567890\r\n"
            + "--\(boundary)--\r\n"

        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/upload"
        )
        head.headers.add(
            name: "content-type",
            value:
                "multipart/form-data; boundary=\(boundary)"
        )
        head.headers.add(
            name: "content-length",
            value: String(body.utf8.count)
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        let bytes = Array(body.utf8)
        var cursor = 0
        let chunkSizes = [1, 7, 2, 31, 3, 11]
        var chunkIndex = 0

        while cursor < bytes.count {
            let requested =
                chunkSizes[
                    chunkIndex
                    % chunkSizes.count
                ]
            let length = min(
                requested,
                bytes.count - cursor
            )
            var chunk = channel.allocator.buffer(
                capacity: length
            )
            chunk.writeBytes(
                bytes[cursor..<(cursor + length)]
            )

            _ = try channel.writeInbound(
                HTTPServerRequestPart.body(chunk)
            )

            cursor += length
            chunkIndex += 1
        }

        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.status,
            .ok
        )
        XCTAssertEqual(
            response.body,
            "Hudhud:demo.bin:10"
        )
    }

    func testInvalidMultipartContentTypeReturns400WithoutParsingBody()
        throws
    {
        let app = Application()

        app.postStream("/upload") { request, _ in
            guard
                (try? MultipartFormDataParser(
                    request: request
                )) != nil
            else {
                return BodyStreamConsumer(
                    onChunk: { _ in },
                    onEnd: {
                        .text(
                            "invalid multipart",
                            status: .badRequest
                        )
                    }
                )
            }

            return BodyStreamConsumer(
                onChunk: { _ in },
                onEnd: {
                    .noContent()
                }
            )
        }

        let channel = try makeChannel(app)
        var head = HTTPRequestHead(
            version: .http1_1,
            method: .POST,
            uri: "/upload"
        )
        head.headers.add(
            name: "content-type",
            value: "application/json"
        )
        head.headers.add(
            name: "content-length",
            value: "2"
        )

        _ = try channel.writeInbound(
            HTTPServerRequestPart.head(head)
        )

        var body = channel.allocator.buffer(
            capacity: 2
        )
        body.writeString("{}")

        _ = try channel.writeInbound(
            HTTPServerRequestPart.body(body)
        )
        _ = try channel.writeInbound(
            HTTPServerRequestPart.end(nil)
        )

        let response = try readResponse(
            from: channel
        )

        XCTAssertEqual(
            response.status,
            .badRequest
        )
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

    private func readResponse(
        from channel: EmbeddedChannel
    ) throws -> (
        status: HTTPResponseStatus,
        body: String
    ) {
        guard
            case .head(let head)? =
                try channel.readOutbound(
                    as:
                        HTTPServerResponsePart.self
                )
        else {
            throw MultipartIntegrationError
                .missingHead
        }

        var body = ""

        while let part = try channel.readOutbound(
            as: HTTPServerResponsePart.self
        ) {
            switch part {
            case .head:
                throw MultipartIntegrationError
                    .unexpectedHead

            case .body(let data):
                guard
                    case .byteBuffer(let buffer) =
                        data
                else {
                    throw MultipartIntegrationError
                        .unexpectedBody
                }

                body += buffer.getString(
                    at: buffer.readerIndex,
                    length: buffer.readableBytes
                ) ?? ""

            case .end:
                return (
                    head.status,
                    body
                )
            }
        }

        throw MultipartIntegrationError
            .missingEnd
    }
}

private enum MultipartIntegrationError: Error {
    case missingHead
    case missingEnd
    case unexpectedHead
    case unexpectedBody
}
