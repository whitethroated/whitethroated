import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import WhiteThroated
import WhiteThroatedCompression
@testable import WhiteThroatedStaticFiles

final class StaticFilesCompressionIntegrationTests:
    XCTestCase
{
    func testCompressionPreservesStaticFileAndRangeRepresentations()
        async throws
    {
        let fixture = try makeFixture()

        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        let files = try await StaticFiles.open(
            directory: fixture.root.path
        )

        do {
            try await MultiThreadedEventLoopGroup
                .withEventLoopGroup(
                    numberOfThreads: 1
                ) { group in
                    let app = Application()

                    app.use(
                        compression: Compression(
                            configuration:
                                Compression.Configuration(
                                    minimumBytes: 0
                                )
                        )
                    )

                    app.mountStatic(
                        "/assets",
                        files: files
                    )

                    let loop = group.next()

                    var fullHeaders = HTTPHeaders()
                    fullHeaders.add(
                        name: "accept-encoding",
                        value: "gzip"
                    )

                    let full = try await app.respond(
                        to: makeRequest(
                            method: .GET,
                            path: "/assets/hello.txt",
                            headers: fullHeaders
                        ),
                        on: loop
                    ).get()

                    XCTAssertEqual(
                        full.status,
                        .ok
                    )
                    XCTAssertNil(
                        full.headers.first(
                            name: "content-encoding"
                        )
                    )
                    XCTAssertEqual(
                        full.headers.first(
                            name: "content-length"
                        ),
                        "11"
                    )
                    XCTAssertEqual(
                        full.headers.first(
                            name: "accept-ranges"
                        ),
                        "bytes"
                    )

                    guard case .stream = full.body else {
                        XCTFail(
                            "Static file compression integration must preserve the streaming file response"
                        )
                        return
                    }

                    var rangeHeaders = HTTPHeaders()
                    rangeHeaders.add(
                        name: "accept-encoding",
                        value: "gzip"
                    )
                    rangeHeaders.add(
                        name: "range",
                        value: "bytes=1-4"
                    )

                    let partial = try await app.respond(
                        to: makeRequest(
                            method: .GET,
                            path: "/assets/hello.txt",
                            headers: rangeHeaders
                        ),
                        on: loop
                    ).get()

                    XCTAssertEqual(
                        partial.status,
                        .partialContent
                    )
                    XCTAssertNil(
                        partial.headers.first(
                            name: "content-encoding"
                        )
                    )
                    XCTAssertEqual(
                        partial.headers.first(
                            name: "content-length"
                        ),
                        "4"
                    )
                    XCTAssertEqual(
                        partial.headers.first(
                            name: "content-range"
                        ),
                        "bytes 1-4/11"
                    )

                    guard case .stream = partial.body else {
                        XCTFail(
                            "Static range compression integration must preserve the streaming file response"
                        )
                        return
                    }
                }

            try await files.close()
        } catch {
            try? await files.close()
            throw error
        }
    }

    private func makeRequest(
        method: NIOHTTP1.HTTPMethod,
        path: String,
        headers: HTTPHeaders
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: path,
                headers: headers
            ),
            body: ByteBufferAllocator()
                .buffer(capacity: 0)
        )
    }

    private func makeFixture() throws -> (
        root: URL,
        file: URL
    ) {
        let root = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )

        try FileManager.default
            .createDirectory(
                at: root,
                withIntermediateDirectories: true
            )

        let file = root.appendingPathComponent(
            "hello.txt"
        )
        try Data("hello world".utf8).write(
            to: file
        )

        return (
            root,
            file
        )
    }
}
