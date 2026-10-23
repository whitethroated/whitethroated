import NIOCore
import NIOHTTP1
import NIOPosix
import WhiteThroatedCompression
import XCTest
@testable import WhiteThroated

final class CompressionTests: XCTestCase {
    private var largeText: String {
        String(
            repeating: "Hello, WhiteThroated! ",
            count: 64
        )
    }

    private var largePlainResponse: Response {
        Response.text(largeText)
    }

    private func makeCompression(
        minimumBytes: Int = 0,
        contentTypes: ContentTypePolicy = .default
    ) -> Compression {
        Compression(
            configuration:
                Compression.Configuration(
                    minimumBytes: minimumBytes,
                    contentTypes: contentTypes
                )
        )
    }

    private func makeRequest(
        method: NIOHTTP1.HTTPMethod = .GET,
        headers: HTTPHeaders = HTTPHeaders()
    ) -> Request {
        Request(
            head: HTTPRequestHead(
                version: .http1_1,
                method: method,
                uri: "/",
                headers: headers
            ),
            body:
                ByteBufferAllocator()
                    .buffer(capacity: 0)
        )
    }

    private func encodingRequest(
        _ value: String
    ) -> Request {
        var headers = HTTPHeaders()

        headers.add(
            name: "accept-encoding",
            value: value
        )

        return makeRequest(headers: headers)
    }

    private func bodyBytes(
        _ response: Response
    ) -> [UInt8]? {
        switch response.body {
        case .text(let value):
            return Array(value.utf8)

        case .bytes(let value):
            return value

        case .buffer(let buffer):
            return Array(buffer.readableBytesView)

        case .empty, .fileRegion, .stream:
            return nil
        }
    }

    private func decodedBody(
        _ response: Response
    ) -> [UInt8]? {
        guard let bytes = bodyBytes(response) else {
            return nil
        }

        if
            response.headers.first(
                name: "content-encoding"
            ) == "gzip"
        {
            return inflateGzip(bytes)
        }

        return bytes
    }

    private func varyTokens(
        _ headers: HTTPHeaders
    ) -> [String] {
        headers[canonicalForm: "vary"]
            .flatMap { value in
                value
                    .split(separator: ",")
                    .map {
                        $0
                            .trimmingCharacters(
                                in: .whitespaces
                            )
                            .lowercased()
                    }
            }
    }

    // MARK: - Encoding

    func testEncodeGzipRoundTrip() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )

        guard let compressed = bodyBytes(response)
        else {
            return XCTFail("expected buffered body")
        }

        XCTAssertGreaterThan(compressed.count, 2)
        XCTAssertEqual(compressed[0], 0x1f)
        XCTAssertEqual(compressed[1], 0x8b)
        XCTAssertEqual(
            response.headers.first(
                name: "content-length"
            ),
            String(compressed.count)
        )
        XCTAssertEqual(
            decodedBody(response),
            Array(largeText.utf8)
        )
        XCTAssertTrue(
            varyTokens(response.headers)
                .contains("accept-encoding")
        )
    }

    func testEncodeBelowMinimumBytesServesIdentity() {
        let text = "small"
        let compression = Compression(
            configuration:
                Compression.Configuration(
                    minimumBytes: 1024
                )
        )

        let response = compression.encode(
            Response.text(text),
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertEqual(
            bodyBytes(response),
            Array(text.utf8)
        )
        XCTAssertTrue(
            varyTokens(response.headers).isEmpty
        )
    }

    func testEncodeAtMinimumBytesCompresses() {
        let text = "0123456789"
        let compression = Compression(
            configuration:
                Compression.Configuration(
                    minimumBytes: text.utf8.count
                )
        )

        let response = compression.encode(
            Response.text(text),
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testEncodeNeverRewritesStatus() {
        let compression = makeCompression()
        let text = largeText

        let response = compression.encode(
            Response.text(
                text,
                status: .created
            ),
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(response.status, .created)
    }

    // MARK: - Negotiation

    func testAbsentAcceptEncodingServesIdentityWithVary() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: makeRequest()
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertEqual(
            bodyBytes(response),
            Array(largeText.utf8)
        )
        XCTAssertTrue(
            varyTokens(response.headers)
                .contains("accept-encoding")
        )
    }

    func testUnsupportedAlgorithmServesIdentityWithVary() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest("br")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyTokens(response.headers)
                .contains("accept-encoding")
        )
    }

    func testWildcardCompresses() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest("*")
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testZeroQualityServesIdentity() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest("gzip;q=0")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
    }

    func testIdentityQualityZeroStillCompresses() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest(
                "gzip;q=0.5, identity;q=0"
            )
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testIdentityDeniedWithNoSupportedAlgorithmFallsBack() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest("identity;q=0")
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(
            bodyBytes(response),
            Array(largeText.utf8)
        )
    }

    func testTokenMatchingIsCaseInsensitive() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest("GZip")
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testMalformedQualityIgnoresElement() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest("gzip;q=abc")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyTokens(response.headers)
                .contains("accept-encoding")
        )
    }

    func testDuplicateTokenUsesHighestQuality() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest(
                "gzip;q=0, gzip;q=1"
            )
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testLowerQualityThanIdentityServesIdentity() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest(
                "gzip;q=0.4, identity;q=0.8"
            )
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
    }

    func testEqualQualityPrefersAlgorithms() {
        let compression = makeCompression()
        let response = compression.encode(
            largePlainResponse,
            for: encodingRequest(
                "gzip;q=0.5, identity;q=0.5"
            )
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testMultipleAcceptEncodingHeadersAreCombined() {
        let compression = makeCompression()
        var headers = HTTPHeaders()

        headers.add(
            name: "accept-encoding",
            value: "br"
        )
        headers.add(
            name: "accept-encoding",
            value: "gzip"
        )

        let response = compression.encode(
            largePlainResponse,
            for: makeRequest(headers: headers)
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    // MARK: - Eligibility

    func testAlreadyEncodedResponseIsUntouched() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "content-encoding",
            value: "br"
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            encoded.headers["content-encoding"],
            ["br"]
        )
        XCTAssertEqual(
            bodyBytes(encoded),
            Array(largeText.utf8)
        )
        XCTAssertTrue(
            varyTokens(encoded.headers).isEmpty
        )
    }

    func testTransferEncodingResponseIsUntouched() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "transfer-encoding",
            value: "chunked"
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            encoded.headers.first(
                name: "content-encoding"
            )
        )
    }

    func testPartialContentIsUntouched() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.status = .partialContent
        response.headers.add(
            name: "content-range",
            value: "bytes 0-10/100"
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            encoded.status,
            .partialContent
        )
        XCTAssertNil(
            encoded.headers.first(
                name: "content-encoding"
            )
        )
    }

    func testBodylessStatusIsUntouched() {
        let compression = makeCompression()
        let response = compression.encode(
            .noContent(),
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(response.status, .noContent)
        XCTAssertTrue(response.headers.isEmpty)
    }

    func testEmptyBodyIsUntouched() {
        let compression = makeCompression()
        let response = compression.encode(
            Response.text(""),
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyTokens(response.headers).isEmpty
        )
    }

    func testPreparedResponseBodyIsUntouchedByEncode() {
        let compression = makeCompression()
        var headers = HTTPHeaders()

        headers.add(
            name: "content-type",
            value: "text/plain"
        )

        let response = compression.encode(
            Response(
                headers: headers,
                body: .empty
            ),
            for: encodingRequest("gzip")
        )

        if case .empty = response.body {
        } else {
            XCTFail("expected empty body")
        }
    }

    func testImageContentTypeIsUntouched() {
        let compression = makeCompression()
        var headers = HTTPHeaders()

        headers.add(
            name: "content-type",
            value: "image/png"
        )

        let response = compression.encode(
            Response(
                headers: headers,
                body: .text(largeText)
            ),
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyTokens(response.headers).isEmpty
        )
    }

    func testMissingContentTypeIsUntouched() {
        let compression = makeCompression()
        let response = compression.encode(
            Response(body: .text(largeText)),
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
    }

    func testContentTypeMatchingIgnoresParametersAndCase() {
        let compression = makeCompression()
        var headers = HTTPHeaders()

        headers.add(
            name: "content-type",
            value: "TEXT/PLAIN; charset=utf-8"
        )

        let response = compression.encode(
            Response(
                headers: headers,
                body: .text(largeText)
            ),
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            response.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testCustomContentTypePolicy() {
        let compression = makeCompression(
            contentTypes: .only(
                ["application/x-custom"]
            )
        )

        var allowedHeaders = HTTPHeaders()
        allowedHeaders.add(
            name: "content-type",
            value: "application/x-custom"
        )

        let allowed = compression.encode(
            Response(
                headers: allowedHeaders,
                body: .text(largeText)
            ),
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            allowed.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )

        let denied = compression.encode(
            largePlainResponse,
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            denied.headers.first(
                name: "content-encoding"
            )
        )
    }

    func testStrongETagBlocksCompression() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "etag",
            value: "\"abc\""
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            encoded.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertTrue(
            varyTokens(encoded.headers).isEmpty
        )
    }

    func testMultipleWeakETagsBlockCompression() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "etag",
            value: "W/\"a\""
        )
        response.headers.add(
            name: "etag",
            value: "W/\"b\""
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            encoded.headers.first(
                name: "content-encoding"
            )
        )
    }

    func testWeakETagKeepsTagWhenCompressed() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "etag",
            value: "W/\"abc\""
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            encoded.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
        XCTAssertEqual(
            encoded.headers.first(name: "etag"),
            "W/\"abc\""
        )
    }

    // MARK: - Vary

    func testVaryIsPreservedAndDeduplicated() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "vary",
            value: "Origin"
        )

        let once = compression.encode(
            response,
            for: encodingRequest("gzip")
        )
        let twice = compression.encode(
            once,
            for: encodingRequest("gzip")
        )

        let tokens = varyTokens(twice.headers)

        XCTAssertTrue(tokens.contains("origin"))
        XCTAssertEqual(
            tokens
                .filter {
                    $0 == "accept-encoding"
                }
                .count,
            1
        )
    }

    func testVaryWildcardIsNotAugmented() {
        let compression = makeCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "vary",
            value: "*"
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            encoded.headers[canonicalForm: "vary"],
            ["*"]
        )
    }

    // MARK: - Precompressed

    func testPrecompressedNegotiatesRepresentations()
        throws
    {
        let compression = makeCompression()
        let handler = try compression.precompressed(
            largePlainResponse
        )

        let encoded = handler(
            encodingRequest("gzip")
        )

        XCTAssertEqual(
            encoded.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
        XCTAssertEqual(
            decodedBody(encoded),
            Array(largeText.utf8)
        )

        let identity = handler(makeRequest())

        XCTAssertNil(
            identity.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertEqual(
            bodyBytes(identity),
            Array(largeText.utf8)
        )
        XCTAssertTrue(
            varyTokens(identity.headers)
                .contains("accept-encoding")
        )
    }

    func testPrecompressedReportedLengthMatchesBody()
        throws
    {
        let compression = makeCompression()
        let handler = try compression.precompressed(
            largePlainResponse
        )

        let encoded = handler(
            encodingRequest("gzip")
        )

        guard
            let compressed = bodyBytes(encoded)
        else {
            return XCTFail("expected buffered body")
        }

        XCTAssertEqual(
            encoded.headers.first(
                name: "content-length"
            ),
            String(compressed.count)
        )
    }

    func testPrecompressedRejectsUnacceptableCoding()
        throws
    {
        let compression = makeCompression()
        let handler = try compression.precompressed(
            largePlainResponse
        )

        let response = handler(
            encodingRequest("identity;q=0, br")
        )

        XCTAssertEqual(
            response.status,
            .notAcceptable
        )
        XCTAssertTrue(
            varyTokens(response.headers)
                .contains("accept-encoding")
        )
    }

    func testPrecompressedWildcardDenialIsNotAcceptable()
        throws
    {
        let compression = makeCompression()
        let handler = try compression.precompressed(
            largePlainResponse
        )

        let response = handler(
            encodingRequest("*;q=0")
        )

        XCTAssertEqual(
            response.status,
            .notAcceptable
        )
    }

    func testPrecompressedStrongETagThrows() {
        var response = largePlainResponse

        response.headers.add(
            name: "etag",
            value: "\"strong\""
        )

        XCTAssertThrowsError(
            try makeCompression()
                .precompressed(response)
        ) { error in
            XCTAssertEqual(
                error as? CompressionError,
                .conflictingETag
            )
        }
    }

    func testPrecompressedIneligibleServesIdentity()
        throws
    {
        let compression = Compression(
            configuration:
                Compression.Configuration(
                    minimumBytes: 1024
                )
        )
        let handler = try compression.precompressed(
            Response.text("tiny")
        )

        let response = handler(
            encodingRequest("gzip")
        )

        XCTAssertNil(
            response.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertEqual(
            bodyBytes(response),
            Array("tiny".utf8)
        )
        XCTAssertTrue(
            varyTokens(response.headers).isEmpty
        )
    }

    // MARK: - Middleware

    func testMiddlewareCompressesImmediateResponse()
        async throws
    {
        let app = Application()
        let text = largeText

        app.use(compression: makeCompression())
        app.get("/") { _ in
            Response.text(text)
        }

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let response = try await app
                    .respond(
                        to: encodingRequest("gzip"),
                        on: loop
                    )
                    .get()

                XCTAssertEqual(
                    response.headers.first(
                        name: "content-encoding"
                    ),
                    "gzip"
                )
                XCTAssertEqual(
                    response.headers.first(
                        name: "content-length"
                    ),
                    String(
                        bodyBytes(response)?
                            .count ?? 0
                    )
                )
            }
    }

    func testMiddlewareCompressesFutureResponse()
        async throws
    {
        let app = Application()
        let text = largeText

        app.use(compression: makeCompression())
        app.get("/") { _, context in
            context.eventLoop.makeSucceededFuture(
                Response.text(text)
            )
        }

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let response = try await app
                    .respond(
                        to: encodingRequest("gzip"),
                        on: loop
                    )
                    .get()

                XCTAssertEqual(
                    response.headers.first(
                        name: "content-encoding"
                    ),
                    "gzip"
                )
                XCTAssertEqual(
                    decodedBody(response),
                    Array(text.utf8)
                )
            }
    }

    func testMiddlewareLeavesPreparedResponsePrepared()
        async throws
    {
        let app = Application()
        let text = largeText

        app.use(compression: makeCompression())
        app.get(
            "/",
            response: PreparedResponse.text(text)
        )

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let result = app.respondFast(
                    to: encodingRequest("gzip"),
                    on: loop
                )

                switch result {
                case .prepared(let prepared):
                    XCTAssertNil(
                        prepared.response.headers
                            .first(
                                name:
                                    "content-encoding"
                            )
                    )

                case .immediate, .future, .streaming:
                    XCTFail(
                        "expected prepared passthrough"
                    )
                }
            }
    }

    func testMiddlewareLeavesIneligibleResponseUntouched()
        async throws
    {
        let app = Application()

        app.use(compression: Compression())
        app.get("/") { _ in
            Response.text("tiny")
        }

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let response = try await app
                    .respond(
                        to: encodingRequest("gzip"),
                        on: loop
                    )
                    .get()

                XCTAssertNil(
                    response.headers.first(
                        name: "content-encoding"
                    )
                )
                XCTAssertEqual(
                    bodyBytes(response),
                    Array("tiny".utf8)
                )
            }
    }

    func testMiddlewareSkipsStreamingResponses()
        async throws
    {
        let app = Application()

        app.use(compression: makeCompression())
        app.get("/") { _, context in
            context.eventLoop.makeSucceededFuture(
                Response.stream { writer in
                    writer.writeAndFlush(
                        ByteBuffer(
                            string: "chunk"
                        )
                    )
                }
            )
        }

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let response = try await app
                    .respond(
                        to: encodingRequest("gzip"),
                        on: loop
                    )
                    .get()

                XCTAssertNil(
                    response.headers.first(
                        name: "content-encoding"
                    )
                )

                if case .stream = response.body {
                } else {
                    XCTFail("expected stream body")
                }
            }
    }

    // MARK: - Policy hook

    private var secretSetCookie: String {
        "session=secret; HttpOnly"
    }

    private func makePolicyCompression(
        minimumBytes: Int = 0
    ) -> Compression {
        Compression(
            configuration:
                Compression.Configuration(
                    minimumBytes: minimumBytes,
                    shouldCompress: { response in
                        response.headers.first(
                            name: "set-cookie"
                        ) == nil
                    }
                )
        )
    }

    func testPolicyHookDeclinesResponseCarryingSecrets() {
        let compression = makePolicyCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "set-cookie",
            value: secretSetCookie
        )

        let encoded = compression.encode(
            response,
            for: encodingRequest("gzip")
        )

        XCTAssertNil(
            encoded.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertEqual(
            bodyBytes(encoded),
            Array(largeText.utf8)
        )
        XCTAssertTrue(
            varyTokens(encoded.headers)
                .contains("accept-encoding")
        )

        // The same response without the secret still encodes:
        // the hook inspects the response, not the route.
        let allowed = compression.encode(
            largePlainResponse,
            for: encodingRequest("gzip")
        )

        XCTAssertEqual(
            allowed.headers.first(
                name: "content-encoding"
            ),
            "gzip"
        )
    }

    func testMiddlewarePolicyHookDeclinesResponseCarryingSecrets()
        async throws
    {
        let app = Application()
        let text = largeText
        let cookie = secretSetCookie

        app.use(
            compression: makePolicyCompression()
        )
        app.get("/") { _ in
            var response = Response.text(text)

            response.headers.add(
                name: "set-cookie",
                value: cookie
            )

            return response
        }

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let response = try await app
                    .respond(
                        to: encodingRequest("gzip"),
                        on: loop
                    )
                    .get()

                XCTAssertNil(
                    response.headers.first(
                        name: "content-encoding"
                    )
                )
                XCTAssertEqual(
                    decodedBody(response),
                    Array(text.utf8)
                )
                XCTAssertTrue(
                    varyTokens(response.headers)
                        .contains("accept-encoding")
                )
            }
    }

    func testMiddlewarePolicyHookDeclinesFutureResponseCarryingSecrets()
        async throws
    {
        let app = Application()
        let text = largeText
        let cookie = secretSetCookie

        app.use(
            compression: makePolicyCompression()
        )
        app.get("/") { _, context in
            var response = Response.text(text)

            response.headers.add(
                name: "set-cookie",
                value: cookie
            )

            return context.eventLoop
                .makeSucceededFuture(response)
        }

        try await MultiThreadedEventLoopGroup
            .withEventLoopGroup(
                numberOfThreads: 1
            ) { group in
                let loop = group.next()

                let response = try await app
                    .respond(
                        to: encodingRequest("gzip"),
                        on: loop
                    )
                    .get()

                XCTAssertNil(
                    response.headers.first(
                        name: "content-encoding"
                    )
                )
                XCTAssertEqual(
                    decodedBody(response),
                    Array(text.utf8)
                )
                XCTAssertTrue(
                    varyTokens(response.headers)
                        .contains("accept-encoding")
                )
            }
    }

    func testPolicyHookDeclinedPrecompressedServesIdentityOnly()
        throws
    {
        let compression = makePolicyCompression()
        var response = largePlainResponse

        response.headers.add(
            name: "set-cookie",
            value: secretSetCookie
        )

        let handler = try compression
            .precompressed(response)

        let served = handler(
            encodingRequest("gzip")
        )

        XCTAssertNil(
            served.headers.first(
                name: "content-encoding"
            )
        )
        XCTAssertEqual(
            bodyBytes(served),
            Array(largeText.utf8)
        )
        XCTAssertTrue(
            varyTokens(served.headers).isEmpty
        )
    }
}
