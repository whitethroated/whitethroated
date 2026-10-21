import Foundation
import NIOCore
import NIOHTTP1
import XCTest

@testable import WhiteThroated
@testable import WhiteThroatedStaticFiles

final class StaticFilesTests: XCTestCase {
    func testPathRejectsTraversalAndEncodedSeparators() {
        XCTAssertNil(
            StaticFilePath.components(
                requestPath: "/assets/../secret.txt",
                mountPath: "/assets",
                indexFile: nil
            )
        )
        XCTAssertNil(
            StaticFilePath.components(
                requestPath: "/assets/%2e%2e/secret.txt",
                mountPath: "/assets",
                indexFile: nil
            )
        )
        XCTAssertNil(
            StaticFilePath.components(
                requestPath: "/assets/a%2fb.txt",
                mountPath: "/assets",
                indexFile: nil
            )
        )
        XCTAssertNil(
            StaticFilePath.components(
                requestPath: "/assets/a%5Cb.txt",
                mountPath: "/assets",
                indexFile: nil
            )
        )
        XCTAssertNil(
            StaticFilePath.components(
                requestPath: "/assets/%00.txt",
                mountPath: "/assets",
                indexFile: nil
            )
        )
        XCTAssertNil(
            StaticFilePath.components(
                requestPath: "/assets/a//b.txt",
                mountPath: "/assets",
                indexFile: nil
            )
        )
    }

    func testPathDecodesExactlyOnce() {
        XCTAssertEqual(
            StaticFilePath.components(
                requestPath: "/assets/%252e%252e.txt",
                mountPath: "/assets",
                indexFile: nil
            ),
            ["%2e%2e.txt"]
        )

        XCTAssertEqual(
            StaticFilePath.components(
                requestPath: "/assets/hello%20world.txt",
                mountPath: "/assets",
                indexFile: nil
            ),
            ["hello world.txt"]
        )
    }

    func testOptionalIndexFile() {
        XCTAssertEqual(
            StaticFilePath.components(
                requestPath: "/assets",
                mountPath: "/assets",
                indexFile: "index.html"
            ),
            ["index.html"]
        )
        XCTAssertEqual(
            StaticFilePath.components(
                requestPath: "/assets/docs/",
                mountPath: "/assets",
                indexFile: "index.html"
            ),
            ["docs", "index.html"]
        )
        XCTAssertNil(
            StaticFilePath.components(
                requestPath: "/assets/docs/",
                mountPath: "/assets",
                indexFile: nil
            )
        )
    }

    func testFileResponseUsesKnownLengthMIMEAndETag() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/hello.txt"
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(
                response.headers.first(
                    name: "content-type"
                ),
                "text/plain; charset=utf-8"
            )
            XCTAssertEqual(
                response.headers.first(
                    name: "content-length"
                ),
                "11"
            )
            XCTAssertEqual(
                response.headers.first(
                    name: "accept-ranges"
                ),
                "bytes"
            )
            XCTAssertNotNil(
                response.headers.first(
                    name: "etag"
                )
            )

            guard case .stream = response.body else {
                XCTFail(
                    "Static GET should use a streaming FileRegion response"
                )
                return
            }
        }
    }

    func testHeadCarriesGetMetadataWithoutOpeningBody() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            let response = await files.response(
                for: makeRequest(
                    method: .HEAD,
                    path: "/assets/hello.txt"
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(
                response.headers.first(
                    name: "content-length"
                ),
                "11"
            )
            XCTAssertNotNil(
                response.headers.first(
                    name: "etag"
                )
            )
        }
    }

    func testSingleRangeProducesPartialContent() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            var headers = HTTPHeaders()
            headers.add(
                name: "range",
                value: "bytes=1-4"
            )

            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/hello.txt",
                    headers: headers
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(
                response.status,
                .partialContent
            )
            XCTAssertEqual(
                response.headers.first(
                    name: "content-length"
                ),
                "4"
            )
            XCTAssertEqual(
                response.headers.first(
                    name: "content-range"
                ),
                "bytes 1-4/11"
            )
        }
    }

    func testIfRangeFallsBackToCompleteRepresentation() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            var headers = HTTPHeaders()
            headers.add(
                name: "range",
                value: "bytes=1-4"
            )
            headers.add(
                name: "if-range",
                value: ""stale""
            )

            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/hello.txt",
                    headers: headers
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(
                response.headers.first(
                    name: "content-length"
                ),
                "11"
            )
            XCTAssertNil(
                response.headers.first(
                    name: "content-range"
                )
            )
        }
    }

    func testUnsatisfiableRangeReturns416() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            var headers = HTTPHeaders()
            headers.add(
                name: "range",
                value: "bytes=50-60"
            )

            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/hello.txt",
                    headers: headers
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(
                response.status,
                .rangeNotSatisfiable
            )
            XCTAssertEqual(
                response.headers.first(
                    name: "content-range"
                ),
                "bytes */11"
            )
        }
    }

    func testIfNoneMatchReturns304() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            let first = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/hello.txt"
                ),
                mountPath: "/assets"
            )

            let tag = try XCTUnwrap(
                first.headers.first(
                    name: "etag"
                )
            )

            var headers = HTTPHeaders()
            headers.add(
                name: "if-none-match",
                value: tag
            )

            let conditional =
                await files.response(
                    for: makeRequest(
                        method: .GET,
                        path: "/assets/hello.txt",
                        headers: headers
                    ),
                    mountPath: "/assets"
                )

            XCTAssertEqual(
                conditional.status,
                .notModified
            )
            XCTAssertEqual(
                conditional.headers.first(
                    name: "etag"
                ),
                tag
            )
        }
    }

    func testEmptyFileUsesKnownZeroLengthResponse() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        let empty = fixture.root
            .appendingPathComponent(
                "empty.txt"
            )
        try Data().write(to: empty)

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/empty.txt"
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(
                response.headers.first(
                    name: "content-length"
                ),
                "0"
            )

            guard case .stream = response.body else {
                XCTFail(
                    "Empty static file should keep known-length stream semantics"
                )
                return
            }
        }
    }

    func testRangeOnEmptyFileReturns416() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        let empty = fixture.root
            .appendingPathComponent(
                "empty.txt"
            )
        try Data().write(to: empty)

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            var headers = HTTPHeaders()
            headers.add(
                name: "range",
                value: "bytes=0-0"
            )

            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/empty.txt",
                    headers: headers
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(
                response.status,
                .rangeNotSatisfiable
            )
            XCTAssertEqual(
                response.headers.first(
                    name: "content-range"
                ),
                "bytes */0"
            )
        }
    }

    func testMIMEOverridesAreCaseInsensitive() {
        let options = StaticFileOptions(
            mimeTypes: [
                "HTML": "application/x-one",
                "html": "application/x-two",
            ]
        )

        XCTAssertEqual(
            options.mimeTypes.count,
            1
        )
        XCTAssertNotNil(
            options.mimeTypes["html"]
        )
    }

    func testFinalSymlinkIsNotServed() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        let outside = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent(
                UUID().uuidString
            )
        try Data("secret".utf8).write(
            to: outside
        )
        defer {
            try? FileManager.default.removeItem(
                at: outside
            )
        }

        let link = fixture.root
            .appendingPathComponent(
                "escape.txt"
            )
        try FileManager.default
            .createSymbolicLink(
                at: link,
                withDestinationURL: outside
            )

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path: "/assets/escape.txt"
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(
                response.status,
                .notFound
            )
        }
    }

    func testIntermediateSymlinkIsNotTraversed() async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.root
            )
        }

        let outsideDirectory = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default
            .createDirectory(
                at: outsideDirectory,
                withIntermediateDirectories: true
            )
        try Data("secret".utf8).write(
            to: outsideDirectory
                .appendingPathComponent(
                    "secret.txt"
                )
        )
        defer {
            try? FileManager.default.removeItem(
                at: outsideDirectory
            )
        }

        try FileManager.default
            .createSymbolicLink(
                at: fixture.root
                    .appendingPathComponent(
                        "linked"
                    ),
                withDestinationURL:
                    outsideDirectory
            )

        try await withStaticFiles(
            directory: fixture.root.path
        ) { files in
            let response = await files.response(
                for: makeRequest(
                    method: .GET,
                    path:
                        "/assets/linked/secret.txt"
                ),
                mountPath: "/assets"
            )

            XCTAssertEqual(
                response.status,
                .notFound
            )
        }
    }

    private func makeRequest(
        method: NIOHTTP1.HTTPMethod,
        path: String,
        headers: HTTPHeaders = HTTPHeaders()
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

    private func withStaticFiles(
        directory: String,
        _ body:
            (StaticFiles) async throws -> Void
    ) async throws {
        let files = try await StaticFiles.open(
            directory: directory
        )

        do {
            try await body(files)
            try await files.close()
        } catch {
            try? await files.close()
            throw error
        }
    }
}
