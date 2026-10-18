import NIOCore
import NIOHTTP1

/// Explicit response-emission subsystem.
///
/// Owns response head emission, content-length handling, body/file/
/// stream emission, connection close semantics, keep-alive behavior,
/// and flush behavior. Plain struct over the channel context: no
/// allocation, no futures, no hops on synchronous paths. Created per
/// response write at call sites that already hold the context.
public struct RuntimeResponseWriter: @unchecked Sendable {
    private static let sharedHTTP11OKHead =
        HTTPResponseHead(
            version: .http1_1,
            status: .ok
        )

    private let context: ChannelHandlerContext

    public init(context: ChannelHandlerContext) {
        self.context = context
    }

    public func writePrepared(
        _ storage: RuntimePreparedResponse,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool,
        onFailure: (Error) -> Void
    ) {
        if
            version == .http1_1,
            keepAlive
        {
            context.write(
                NIOAny(
                    HTTPServerResponsePart.head(
                        storage.http11Head
                    )
                ),
                promise: nil
            )

            if
                !isHeadRequest,
                let body = storage.bodyBuffer
            {
                context.write(
                    NIOAny(
                        HTTPServerResponsePart.body(
                            .byteBuffer(body)
                        )
                    ),
                    promise: nil
                )
            }

            context.writeAndFlush(
                NIOAny(
                    HTTPServerResponsePart.end(nil)
                ),
                promise: nil
            )
            return
        }

        guard storage.status.mayHaveResponseBody else {
            writeBodylessStatus(
                storage.response,
                version: version,
                keepAlive: keepAlive
            )
            return
        }

        // Prepared bodies are always buffers, never streams, so
        // onFailure cannot fire here; it only satisfies the shared
        // writer path below.
        write(
            storage.response,
            onFailure: onFailure,
            isHeadRequest: isHeadRequest,
            version: version,
            keepAlive: keepAlive
        )
    }

    @inline(__always)
    public func writeMinimal(
        _ response: RuntimeResponse,
        isHeadRequest: Bool,
        onFailure: (Error) -> Void
    ) {
        if writeCanonicalText(
            response,
            isHeadRequest: isHeadRequest
        ) {
            return
        }

        write(
            response,
            onFailure: onFailure,
            isHeadRequest: isHeadRequest,
            version: .http1_1,
            keepAlive: true
        )
    }

    @inline(__always)
    public func writeCanonicalText(
        _ response: RuntimeResponse,
        isHeadRequest: Bool
    ) -> Bool {
        guard
            let canonicalHead =
                response.canonicalHead,
            let canonicalBodyLength =
                response.canonicalBodyLength,
            case .text(let value) = response.body
        else {
            return false
        }

        context.write(
            NIOAny(
                HTTPServerResponsePart.head(
                    canonicalHead
                )
            ),
            promise: nil
        )

        if
            !isHeadRequest,
            canonicalBodyLength > 0
        {
            var valueBuffer =
                context.channel.allocator.buffer(
                    capacity:
                        canonicalBodyLength
                )
            valueBuffer.writeString(value)

            context.write(
                NIOAny(
                    HTTPServerResponsePart.body(
                        .byteBuffer(
                            valueBuffer
                        )
                    )
                ),
                promise: nil
            )
        }

        context.writeAndFlush(
            NIOAny(
                HTTPServerResponsePart.end(nil)
            ),
            promise: nil
        )
        return true
    }

    public func write(
        _ response: RuntimeResponse,
        onFailure: (Error) -> Void,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool
    ) {
        guard response.status.mayHaveResponseBody else {
            writeBodylessStatus(
                response,
                version: version,
                keepAlive: keepAlive
            )
            return
        }

        if case .stream(let stream) = response.body {
            writeStream(
                stream,
                response: response,
                onFailure: onFailure,
                isHeadRequest: isHeadRequest,
                version: version,
                keepAlive: keepAlive
            )
            return
        }

        if
            version == .http1_1,
            keepAlive,
            writeCanonicalText(
                response,
                isHeadRequest: isHeadRequest
            )
        {
            return
        }

        let canonicalHead =
            version == .http1_1 && keepAlive
            ? response.canonicalHead
            : nil

        let body: IOData?
        let bodyLength: Int

        switch response.body {
        case .empty:
            body = nil
            bodyLength = 0

        case .text(let value):
            var valueBuffer =
                context.channel.allocator.buffer(
                    capacity: value.utf8.count
                )
            valueBuffer.writeString(value)
            body = .byteBuffer(valueBuffer)
            bodyLength = valueBuffer.readableBytes

        case .bytes(let bytes):
            var valueBuffer =
                context.channel.allocator.buffer(
                    capacity: bytes.count
                )
            valueBuffer.writeBytes(bytes)
            body = .byteBuffer(valueBuffer)
            bodyLength = valueBuffer.readableBytes

        case .buffer(let value):
            body = .byteBuffer(value)
            bodyLength = value.readableBytes

        case .fileRegion(let value):
            body = .fileRegion(value)
            bodyLength = value.readableBytes

        case .stream:
            preconditionFailure(
                "Stream bodies must use the streaming response writer"
            )
        }

        let head: HTTPResponseHead

        if let canonicalHead {
            head = canonicalHead
        } else {
            var headers = response.headers

            if !response.contentLengthIsNormalized {
                let contentLengthValue =
                    String(bodyLength)

                if !HTTPContentLength.hasSingleExactValue(
                    headers,
                    value: contentLengthValue
                ) {
                    headers.replaceOrAdd(
                        name: "content-length",
                        value: contentLengthValue
                    )
                }
            }

            if !keepAlive {
                headers.replaceOrAdd(
                    name: "connection",
                    value: "close"
                )
            } else if version == .http1_0 {
                headers.replaceOrAdd(
                    name: "connection",
                    value: "keep-alive"
                )
            }

            if
                version == .http1_1,
                response.status == .ok
            {
                var cachedHead =
                    Self.sharedHTTP11OKHead
                cachedHead.headers = headers
                head = cachedHead
            } else {
                head = HTTPResponseHead(
                    version: version,
                    status: response.status,
                    headers: headers
                )
            }
        }

        context.write(
            NIOAny(
                HTTPServerResponsePart.head(head)
            ),
            promise: nil
        )

        if
            !isHeadRequest,
            let body,
            bodyLength > 0
        {
            context.write(
                NIOAny(
                    HTTPServerResponsePart.body(body)
                ),
                promise: nil
            )
        }

        finishResponse(keepAlive: keepAlive)
    }

    public func writeBodylessStatus(
        _ response: RuntimeResponse,
        version: HTTPVersion,
        keepAlive: Bool
    ) {
        var headers = response.headers

        headers.remove(
            name: "transfer-encoding"
        )

        if response.status != .notModified {
            headers.remove(
                name: "content-length"
            )
        }

        if !keepAlive {
            headers.replaceOrAdd(
                name: "connection",
                value: "close"
            )
        } else if version == .http1_0 {
            headers.replaceOrAdd(
                name: "connection",
                value: "keep-alive"
            )
        }

        let head = HTTPResponseHead(
            version: version,
            status: response.status,
            headers: headers
        )

        context.write(
            NIOAny(
                HTTPServerResponsePart.head(head)
            ),
            promise: nil
        )

        finishResponse(keepAlive: keepAlive)
    }

    public func writeStream(
        _ stream: RuntimeResponseStream,
        response: RuntimeResponse,
        onFailure: (Error) -> Void,
        isHeadRequest: Bool,
        version: HTTPVersion,
        keepAlive: Bool
    ) {
        var headers = response.headers
        let declaredLengthResult:
            Result<Int?, RuntimeStreamError>

        if
            response.contentLengthIsNormalized,
            let expectedContentLength =
                stream.expectedContentLength
        {
            declaredLengthResult =
                .success(
                    expectedContentLength
                )
        } else {
            declaredLengthResult =
                Self.declaredStreamContentLength(
                    headers: headers
                )
        }

        let lengthTracker:
            RuntimeStreamLengthTracker?

        switch declaredLengthResult {
        case .success(let declaredLength):
            if let declaredLength {
                lengthTracker =
                    RuntimeStreamLengthTracker(
                        expected: declaredLength
                    )
            } else {
                lengthTracker = nil
            }

        case .failure(let error):
            stream.onError?(error)
            onFailure(error)
            return
        }

        let hasKnownLength =
            lengthTracker != nil
        let streamKeepAlive =
            keepAlive
            && (
                version != .http1_0
                || hasKnownLength
            )

        if !streamKeepAlive {
            headers.replaceOrAdd(
                name: "connection",
                value: "close"
            )
        } else if version == .http1_0 {
            headers.replaceOrAdd(
                name: "connection",
                value: "keep-alive"
            )
        }

        let head = HTTPResponseHead(
            version: version,
            status: response.status,
            headers: headers
        )

        context.write(
            NIOAny(
                HTTPServerResponsePart.head(head)
            ),
            promise: nil
        )

        if isHeadRequest {
            finishStreamResponse(
                keepAlive: streamKeepAlive
            )
            return
        }

        let writer = RuntimeStreamWriter(
            context: context,
            lengthTracker: lengthTracker
        )
        let future = stream.produce(writer).hop(
            to: context.eventLoop
        )
        let context = context

        future
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { result in
                guard context.channel.isActive else {
                return
            }

            switch result {
            case .success:
                if let error =
                    lengthTracker?.completionError()
                {
                    stream.onError?(error)
                    context.flush()
                    context.close(promise: nil)
                    return
                }

                Self.finishStreamResponse(
                    keepAlive: streamKeepAlive,
                    context: context
                )

            case .failure(let error):
                stream.onError?(error)
                context.flush()
                context.close(promise: nil)
            }
        }
    }

    @inline(__always)
    public func finishResponse(
        keepAlive: Bool
    ) {
        if keepAlive {
            context.writeAndFlush(
                NIOAny(
                    HTTPServerResponsePart.end(nil)
                ),
                promise: nil
            )
            return
        }

        context
            .writeAndFlush(
                NIOAny(
                    HTTPServerResponsePart.end(nil)
                )
            )
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { _ in
                context.close(
                    promise: nil
                )
            }
    }

    @inline(__always)
    public func finishStreamResponse(
        keepAlive: Bool
    ) {
        finishResponse(keepAlive: keepAlive)
    }

    @inline(__always)
    private static func finishStreamResponse(
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        if keepAlive {
            context.writeAndFlush(
                NIOAny(
                    HTTPServerResponsePart.end(nil)
                ),
                promise: nil
            )
            return
        }

        context
            .writeAndFlush(
                NIOAny(
                    HTTPServerResponsePart.end(nil)
                )
            )
            .assumeIsolatedUnsafeUnchecked()
            .whenComplete { _ in
                context.close(
                    promise: nil
                )
            }
    }

    @inline(__always)
    internal static func declaredStreamContentLength(
        headers: HTTPHeaders
    ) -> Result<Int?, RuntimeStreamError> {
        var firstRawValue: String?
        var parsedLength: Int?

        for (name, value) in headers {
            guard isContentLengthHeader(name) else {
                continue
            }

            if let firstRawValue {
                return .failure(
                    .ambiguousContentLength([
                        firstRawValue,
                        value
                    ])
                )
            }

            if value.utf8.contains(44) {
                return .failure(
                    .ambiguousContentLength([
                        value
                    ])
                )
            }

            guard let contentLength =
                parseContentLength(value)
            else {
                return .failure(
                    .invalidContentLength(value)
                )
            }

            firstRawValue = value
            parsedLength = contentLength
        }

        return .success(parsedLength)
    }

    @inline(__always)
    private static func isContentLengthHeader(
        _ name: String
    ) -> Bool {
        let bytes = name.utf8
        let expected = "content-length".utf8

        guard bytes.count == expected.count else {
            return false
        }

        var left = bytes.startIndex
        var right = expected.startIndex

        while left != bytes.endIndex {
            let byte = bytes[left]
            let folded =
                byte >= 65 && byte <= 90
                ? byte + 32
                : byte

            guard folded == expected[right] else {
                return false
            }

            bytes.formIndex(after: &left)
            expected.formIndex(after: &right)
        }

        return true
    }

    @inline(__always)
    private static func parseContentLength(
        _ value: String
    ) -> Int? {
        let bytes = value.utf8

        guard !bytes.isEmpty else {
            return nil
        }

        var result = 0

        for byte in bytes {
            guard byte >= 48 && byte <= 57 else {
                return nil
            }

            let digit = Int(byte - 48)

            guard
                result
                <= (Int.max - digit) / 10
            else {
                return nil
            }

            result =
                result * 10
                + digit
        }

        return result
    }
}
