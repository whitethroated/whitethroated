import NIOCore
import NIOHTTP1
import WhiteThroatedRuntime

/// Framework-to-runtime boundary conversions.
///
/// All conversions run on the connection event loop at dispatch time.
/// They are shallow value copies (status, CoW headers, body enum);
/// no I/O, no hops, no Tasks. Stream bodies adapt producers across
/// the boundary; stream paths are cold relative to the sync fast path.
extension Response {
    /// Framework-to-runtime boundary crossing. A `consuming`
    /// function variant measured noise-identical in the in-process
    /// transport matrix and was reverted to keep this simpler shape.
    @inline(__always)
    internal var runtimeResponse: RuntimeResponse {
        RuntimeResponse(
            status: status,
            headers: headers,
            body: body.runtimeBody,
            contentLengthIsNormalized:
                contentLengthIsNormalized,
            canonicalHead: canonicalHTTP11Head,
            canonicalBodyLength:
                canonicalHTTP11BodyLength
        )
    }
}

extension Response.Body {
    @inline(__always)
    internal var runtimeBody: RuntimeResponseBody {
        switch self {
        case .empty:
            return .empty

        case .text(let value):
            return .text(value)

        case .bytes(let value):
            return .bytes(value)

        case .buffer(let value):
            return .buffer(value)

        case .fileRegion(let value):
            return .fileRegion(value)

        case .stream(let stream):
            return .stream(
                stream.runtimeStream
            )
        }
    }
}

extension ResponseStream {
    internal var runtimeStream: RuntimeResponseStream {
        let producer = producer
        let errorHandler = errorHandler

        var runtimeStream = RuntimeResponseStream(
            produce: {
                (runtimeWriter: RuntimeStreamWriter) in
                producer(
                    ResponseStreamWriter(
                        runtimeWriter:
                            runtimeWriter
                    )
                )
            },
            expectedContentLength:
                expectedContentLength
        )

        if let errorHandler {
            runtimeStream.onError = { error in
                errorHandler(
                    mapRuntimeStreamError(error)
                )
            }
        }

        return runtimeStream
    }
}

extension ResponderResult {
    internal func asRuntimeDispatchResult(
        on eventLoop: EventLoop
    ) -> RuntimeDispatchResult {
        switch self {
        case .immediate(let response):
            return .response(
                response.runtimeResponse
            )

        case .prepared(let storage):
            return .prepared(
                storage.runtimeStorage
            )

        case .streaming(let session):
            return .future(
                session.responseFuture.map {
                    $0.runtimeResponse
                }
            )

        case .future(let future):
            return .future(
                future.map {
                    $0.runtimeResponse
                }
            )
        }
    }
}

/// Maps transport-side response-stream errors onto the public
/// framework error type. Passes producer failures through untouched.
internal func mapRuntimeStreamError(
    _ error: Error
) -> Error {
    guard let streamError =
        error as? RuntimeStreamError
    else {
        return error
    }

    switch streamError {
    case .invalidContentLength(let value):
        return ResponseStreamError
            .invalidContentLength(value)

    case .ambiguousContentLength(let values):
        return ResponseStreamError
            .ambiguousContentLength(values)

    case .contentLengthExceeded(
        let expected,
        let attempted
    ):
        return ResponseStreamError
            .contentLengthExceeded(
                expected: expected,
                attempted: attempted
            )

    case .contentLengthMismatch(
        let expected,
        let actual
    ):
        return ResponseStreamError
            .contentLengthMismatch(
                expected: expected,
                actual: actual
            )
    }
}

/// Maps transport-side request-stream errors onto the public
/// framework error type. Passes consumer failures through untouched.
internal func mapRuntimeRequestStreamError(
    _ error: Error
) -> Error {
    guard let streamError =
        error as? RuntimeRequestStreamError
    else {
        return error
    }

    switch streamError {
    case .payloadTooLarge:
        return BodyStreamError.payloadTooLarge

    case .connectionClosed:
        return BodyStreamError.connectionClosed
    }
}
