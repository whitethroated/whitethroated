import Foundation
import NIOCore
import NIOPosix

private enum ParsedMethod: Equatable {
    case get
    case post
    case head
    case other
}

private enum ParseResult {
    case incomplete
    case invalid
    case complete(ParsedRequest)
}

private struct ParsedRequest {
    let method: ParsedMethod
    let targetOffset: Int
    let targetLength: Int
    let consumedBytes: Int
    let keepAlive: Bool
}

private let hostHeaderName = Array("host".utf8)
private let contentLengthHeaderName = Array("content-length".utf8)
private let transferEncodingHeaderName = Array("transfer-encoding".utf8)
private let connectionHeaderName = Array("connection".utf8)
private let expectHeaderName = Array("expect".utf8)
private let closeToken = Array("close".utf8)

private let slash = Array("/".utf8)
private let preparedPath = Array("/prepared".utf8)
private let jsonPath = Array("/json".utf8)
private let userPath = Array("/user".utf8)
private let userPrefix = Array("/user/".utf8)

private let maxHeaderBytes = 16 * 1024
private let maxBodyBytes = 16 * 1024 * 1024

@inline(__always)
private func foldedLowercase(_ byte: UInt8) -> UInt8 {
    if byte >= 65 && byte <= 90 {
        return byte &+ 32
    }
    return byte
}

@inline(__always)
private func equalsCaseInsensitive(
    _ bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    end: Int,
    literal: [UInt8]
) -> Bool {
    guard end - start == literal.count else {
        return false
    }

    var index = 0
    while index < literal.count {
        if foldedLowercase(bytes[start + index]) != literal[index] {
            return false
        }
        index += 1
    }

    return true
}

@inline(__always)
private func equalsBytes(
    _ bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    end: Int,
    literal: [UInt8]
) -> Bool {
    guard end - start == literal.count else {
        return false
    }

    var index = 0
    while index < literal.count {
        if bytes[start + index] != literal[index] {
            return false
        }
        index += 1
    }

    return true
}

@inline(__always)
private func startsWithBytes(
    _ bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    end: Int,
    literal: [UInt8]
) -> Bool {
    guard end - start >= literal.count else {
        return false
    }

    var index = 0
    while index < literal.count {
        if bytes[start + index] != literal[index] {
            return false
        }
        index += 1
    }

    return true
}

@inline(__always)
private func findCRLF(
    _ bytes: UnsafeBufferPointer<UInt8>,
    from start: Int,
    limit: Int
) -> Int? {
    guard start + 1 < limit else {
        return nil
    }

    var index = start
    while index + 1 < limit {
        if bytes[index] == 13 && bytes[index + 1] == 10 {
            return index
        }
        index += 1
    }

    return nil
}

@inline(__always)
private func findHeaderEnd(
    _ bytes: UnsafeBufferPointer<UInt8>
) -> Int? {
    guard bytes.count >= 4 else {
        return nil
    }

    let limit = min(bytes.count, maxHeaderBytes + 4)
    var index = 0

    while index + 3 < limit {
        if
            bytes[index] == 13,
            bytes[index + 1] == 10,
            bytes[index + 2] == 13,
            bytes[index + 3] == 10
        {
            return index
        }
        index += 1
    }

    return nil
}

@inline(__always)
private func trimOWS(
    _ bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    end: Int
) -> (Int, Int) {
    var lower = start
    var upper = end

    while lower < upper {
        let byte = bytes[lower]
        if byte == 32 || byte == 9 {
            lower += 1
        } else {
            break
        }
    }

    while upper > lower {
        let byte = bytes[upper - 1]
        if byte == 32 || byte == 9 {
            upper -= 1
        } else {
            break
        }
    }

    return (lower, upper)
}

@inline(__always)
private func isHeaderNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 33, 35...39, 42, 43, 45, 46, 48...57, 65...90, 94...122, 124, 126:
        return true
    default:
        return false
    }
}

@inline(__always)
private func validHeaderValueByte(_ byte: UInt8) -> Bool {
    byte == 9 || (byte >= 32 && byte != 127)
}

@inline(__always)
private func parseDecimal(
    _ bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    end: Int
) -> Int? {
    guard start < end else {
        return nil
    }

    var value = 0
    var index = start

    while index < end {
        let byte = bytes[index]
        guard byte >= 48 && byte <= 57 else {
            return nil
        }

        let digit = Int(byte - 48)
        guard value <= (maxBodyBytes - digit) / 10 else {
            return nil
        }

        value = value * 10 + digit
        index += 1
    }

    return value
}

@inline(__always)
private func valueContainsToken(
    _ bytes: UnsafeBufferPointer<UInt8>,
    start: Int,
    end: Int,
    token: [UInt8]
) -> Bool {
    var fieldStart = start

    while fieldStart < end {
        var fieldEnd = fieldStart
        while fieldEnd < end && bytes[fieldEnd] != 44 {
            fieldEnd += 1
        }

        let trimmed = trimOWS(
            bytes,
            start: fieldStart,
            end: fieldEnd
        )

        if equalsCaseInsensitive(
            bytes,
            start: trimmed.0,
            end: trimmed.1,
            literal: token
        ) {
            return true
        }

        fieldStart = fieldEnd + 1
    }

    return false
}

private func parseRequest(
    _ buffer: ByteBuffer
) -> ParseResult {
    buffer.withUnsafeReadableBytes { rawBytes in
        let bytes = rawBytes.bindMemory(to: UInt8.self)

        guard let headerEnd = findHeaderEnd(bytes) else {
            return bytes.count > maxHeaderBytes
                ? .invalid
                : .incomplete
        }

        guard
            let requestLineEnd = findCRLF(
                bytes,
                from: 0,
                limit: headerEnd + 2
            ),
            requestLineEnd > 0
        else {
            return .invalid
        }

        var firstSpace: Int?
        var secondSpace: Int?
        var index = 0

        while index < requestLineEnd {
            if bytes[index] == 32 {
                if firstSpace == nil {
                    firstSpace = index
                } else {
                    secondSpace = index
                    break
                }
            }
            index += 1
        }

        guard
            let firstSpace,
            let secondSpace,
            firstSpace > 0,
            secondSpace > firstSpace + 1
        else {
            return .invalid
        }

        let method: ParsedMethod

        if
            firstSpace == 3,
            bytes[0] == 71,
            bytes[1] == 69,
            bytes[2] == 84
        {
            method = .get
        } else if
            firstSpace == 4,
            bytes[0] == 80,
            bytes[1] == 79,
            bytes[2] == 83,
            bytes[3] == 84
        {
            method = .post
        } else if
            firstSpace == 4,
            bytes[0] == 72,
            bytes[1] == 69,
            bytes[2] == 65,
            bytes[3] == 68
        {
            method = .head
        } else {
            method = .other
        }

        let targetStart = firstSpace + 1
        let targetEnd = secondSpace

        guard bytes[targetStart] == 47 else {
            return .invalid
        }

        let versionStart = secondSpace + 1
        guard requestLineEnd - versionStart == 8 else {
            return .invalid
        }

        let isHTTP11 =
            bytes[versionStart] == 72
            && bytes[versionStart + 1] == 84
            && bytes[versionStart + 2] == 84
            && bytes[versionStart + 3] == 80
            && bytes[versionStart + 4] == 47
            && bytes[versionStart + 5] == 49
            && bytes[versionStart + 6] == 46
            && bytes[versionStart + 7] == 49

        guard isHTTP11 else {
            return .invalid
        }

        var hostSeen = false
        var contentLength: Int?
        var transferEncodingSeen = false
        var expectSeen = false
        var connectionClose = false

        var lineStart = requestLineEnd + 2

        while lineStart < headerEnd {
            guard
                let lineEnd = findCRLF(
                    bytes,
                    from: lineStart,
                    limit: headerEnd + 2
                ),
                lineEnd <= headerEnd
            else {
                return .invalid
            }

            guard lineEnd > lineStart else {
                break
            }

            var colon: Int?
            index = lineStart

            while index < lineEnd {
                let byte = bytes[index]

                if byte == 58 {
                    colon = index
                    break
                }

                guard isHeaderNameByte(byte) else {
                    return .invalid
                }

                index += 1
            }

            guard
                let colon,
                colon > lineStart
            else {
                return .invalid
            }

            index = colon + 1
            while index < lineEnd {
                guard validHeaderValueByte(bytes[index]) else {
                    return .invalid
                }
                index += 1
            }

            let value = trimOWS(
                bytes,
                start: colon + 1,
                end: lineEnd
            )

            if equalsCaseInsensitive(
                bytes,
                start: lineStart,
                end: colon,
                literal: hostHeaderName
            ) {
                guard !hostSeen, value.0 < value.1 else {
                    return .invalid
                }
                hostSeen = true
            } else if equalsCaseInsensitive(
                bytes,
                start: lineStart,
                end: colon,
                literal: contentLengthHeaderName
            ) {
                guard
                    contentLength == nil,
                    let parsed = parseDecimal(
                        bytes,
                        start: value.0,
                        end: value.1
                    )
                else {
                    return .invalid
                }
                contentLength = parsed
            } else if equalsCaseInsensitive(
                bytes,
                start: lineStart,
                end: colon,
                literal: transferEncodingHeaderName
            ) {
                transferEncodingSeen = true
            } else if equalsCaseInsensitive(
                bytes,
                start: lineStart,
                end: colon,
                literal: expectHeaderName
            ) {
                expectSeen = true
            } else if equalsCaseInsensitive(
                bytes,
                start: lineStart,
                end: colon,
                literal: connectionHeaderName
            ) {
                connectionClose =
                    connectionClose
                    || valueContainsToken(
                        bytes,
                        start: value.0,
                        end: value.1,
                        token: closeToken
                    )
            }

            lineStart = lineEnd + 2
        }

        guard hostSeen else {
            return .invalid
        }

        guard
            !transferEncodingSeen,
            !expectSeen
        else {
            return .invalid
        }

        let bodyLength = contentLength ?? 0
        guard bodyLength <= maxBodyBytes else {
            return .invalid
        }

        let headerBytes = headerEnd + 4
        let totalBytes = headerBytes + bodyLength

        guard bytes.count >= totalBytes else {
            return .incomplete
        }

        return .complete(
            ParsedRequest(
                method: method,
                targetOffset: targetStart,
                targetLength: targetEnd - targetStart,
                consumedBytes: totalBytes,
                keepAlive: !connectionClose
            )
        )
    }
}

private struct WireResponses {
    let allocator: ByteBufferAllocator
    let emptyOK: ByteBuffer
    let plaintextOK: ByteBuffer
    let plaintextHead: ByteBuffer
    let jsonOK: ByteBuffer
    let jsonHead: ByteBuffer
    let notFound: ByteBuffer
    let badRequest: ByteBuffer
    let parameterHeads: [ByteBuffer]

    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator

        self.emptyOK = Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n"
        )

        self.plaintextOK = Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 13\r\ndate: Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\nHello, World!"
        )

        self.plaintextHead = Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 13\r\ndate: Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n"
        )

        self.jsonOK = Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 200 OK\\r\\ncontent-type: application/json; charset=utf-8\\r\\ncontent-length: 27\\r\\n\\r\\n{\\\"message\\\":\\\"Hello, World!\\\"}"
        )

        self.jsonHead = Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json; charset=utf-8\r\ncontent-length: 27\r\n\r\n"
        )

        self.notFound = Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n"
        )

        self.badRequest = Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        )

        self.parameterHeads =
            (0...64).map { length in
                Self.makeBuffer(
                    allocator: allocator,
                    "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: \(length)\r\n\r\n"
                )
            }
    }

    private static func makeBuffer(
        allocator: ByteBufferAllocator,
        _ string: String
    ) -> ByteBuffer {
        var buffer = allocator.buffer(
            capacity: string.utf8.count
        )
        buffer.writeString(string)
        return buffer
    }

    func parameterHead(length: Int) -> ByteBuffer {
        if length <= 64 {
            return parameterHeads[length]
        }

        return Self.makeBuffer(
            allocator: allocator,
            "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: \(length)\r\n\r\n"
        )
    }
}

private final class CustomHTTP1BenchmarkHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let responses: WireResponses
    private var pending: ByteBuffer?

    init(allocator: ByteBufferAllocator) {
        self.responses = WireResponses(
            allocator: allocator
        )
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        var incoming = unwrapInboundIn(data)

        if var buffered = pending {
            pending = nil
            buffered.writeBuffer(&incoming)
            process(
                &buffered,
                context: context
            )

            if buffered.readableBytes > 0 {
                pending = buffered
            }
            return
        }

        process(
            &incoming,
            context: context
        )

        if incoming.readableBytes > 0 {
            pending = incoming
        }
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        context.close(promise: nil)
    }

    private func process(
        _ buffer: inout ByteBuffer,
        context: ChannelHandlerContext
    ) {
        while buffer.readableBytes > 0 {
            switch parseRequest(buffer) {
            case .incomplete:
                return

            case .invalid:
                pending = nil
                context
                    .writeAndFlush(
                        wrapOutboundOut(
                            responses.badRequest
                        )
                    )
                    .whenComplete { _ in
                        context.close(
                            promise: nil
                        )
                    }
                buffer.moveReaderIndex(
                    to: buffer.writerIndex
                )
                return

            case .complete(let request):
                let requestBase =
                    buffer.readerIndex

                respond(
                    request,
                    requestBase: requestBase,
                    buffer: buffer,
                    context: context
                )

                buffer.moveReaderIndex(
                    forwardBy:
                        request.consumedBytes
                )

                if !request.keepAlive {
                    buffer.moveReaderIndex(
                        to: buffer.writerIndex
                    )
                    return
                }
            }
        }
    }

    @inline(__always)
    private func respond(
        _ request: ParsedRequest,
        requestBase: Int,
        buffer: ByteBuffer,
        context: ChannelHandlerContext
    ) {
        let targetStart =
            requestBase
            + request.targetOffset
        let targetEnd =
            targetStart
            + request.targetLength

        let targetMatches: (UnsafeBufferPointer<UInt8>) -> Void = { bytes in
            switch request.method {
            case .get, .head:
                let isHead =
                    request.method == .head

                if equalsBytes(
                    bytes,
                    start: 0,
                    end: bytes.count,
                    literal: slash
                ) {
                    self.write(
                        self.responses.emptyOK,
                        keepAlive:
                            request.keepAlive,
                        context: context
                    )
                    return
                }

                if equalsBytes(
                    bytes,
                    start: 0,
                    end: bytes.count,
                    literal: preparedPath
                ) {
                    self.write(
                        isHead
                            ? self.responses.plaintextHead
                            : self.responses.plaintextOK,
                        keepAlive:
                            request.keepAlive,
                        context: context
                    )
                    return
                }

                if equalsBytes(
                    bytes,
                    start: 0,
                    end: bytes.count,
                    literal: jsonPath
                ) {
                    self.write(
                        isHead
                            ? self.responses.jsonHead
                            : self.responses.jsonOK,
                        keepAlive:
                            request.keepAlive,
                        context: context
                    )
                    return
                }

                if
                    startsWithBytes(
                        bytes,
                        start: 0,
                        end: bytes.count,
                        literal: userPrefix
                    ),
                    bytes.count > userPrefix.count
                {
                    let identifierStart =
                        userPrefix.count
                    var index =
                        identifierStart

                    while index < bytes.count {
                        if
                            bytes[index] == 47
                            || bytes[index] == 63
                        {
                            self.write(
                                self.responses
                                    .notFound,
                                keepAlive:
                                    request.keepAlive,
                                context: context
                            )
                            return
                        }
                        index += 1
                    }

                    let identifierLength =
                        bytes.count
                        - identifierStart
                    let head =
                        self.responses
                            .parameterHead(
                                length:
                                    identifierLength
                            )

                    if isHead {
                        self.write(
                            head,
                            keepAlive:
                                request.keepAlive,
                            context: context
                        )
                        return
                    }

                    guard
                        let body =
                            buffer.getSlice(
                                at:
                                    targetStart
                                    + identifierStart,
                                length:
                                    identifierLength
                            )
                    else {
                        self.write(
                            self.responses
                                .badRequest,
                            keepAlive: false,
                            context: context
                        )
                        return
                    }

                    context.write(
                        self.wrapOutboundOut(
                            head
                        ),
                        promise: nil
                    )

                    self.write(
                        body,
                        keepAlive:
                            request.keepAlive,
                        context: context
                    )
                    return
                }

            case .post:
                if equalsBytes(
                    bytes,
                    start: 0,
                    end: bytes.count,
                    literal: userPath
                ) {
                    self.write(
                        self.responses.emptyOK,
                        keepAlive:
                            request.keepAlive,
                        context: context
                    )
                    return
                }

            case .other:
                break
            }

            self.write(
                self.responses.notFound,
                keepAlive:
                    request.keepAlive,
                context: context
            )
        }

        guard
            let target =
                buffer.getSlice(
                    at: targetStart,
                    length:
                        request.targetLength
                )
        else {
            write(
                responses.badRequest,
                keepAlive: false,
                context: context
            )
            return
        }

        target.withUnsafeReadableBytes { raw in
            targetMatches(
                raw.bindMemory(
                    to: UInt8.self
                )
            )
        }
    }

    @inline(__always)
    private func write(
        _ buffer: ByteBuffer,
        keepAlive: Bool,
        context: ChannelHandlerContext
    ) {
        if keepAlive {
            context.writeAndFlush(
                wrapOutboundOut(buffer),
                promise: nil
            )
            return
        }

        context
            .writeAndFlush(
                wrapOutboundOut(buffer)
            )
            .whenComplete { _ in
                context.close(
                    promise: nil
                )
            }
    }
}

let environment =
    ProcessInfo.processInfo.environment

let host =
    environment[
        "WHITETHROATED_HOST"
    ] ?? "127.0.0.1"

let port =
    Int(
        environment[
            "WHITETHROATED_PORT"
        ] ?? "3000"
    ) ?? 3000

let eventLoopThreads =
    Int(
        environment[
            "WHITETHROATED_THREADS"
        ] ?? ""
    ) ?? System.coreCount

let group =
    MultiThreadedEventLoopGroup(
        numberOfThreads:
            eventLoopThreads
    )

let bootstrap =
    ServerBootstrap(group: group)
        .serverChannelOption(
            ChannelOptions.backlog,
            value: 256
        )
        .serverChannelOption(
            ChannelOptions.socketOption(
                .so_reuseaddr
            ),
            value: 1
        )
        .childChannelOption(
            ChannelOptions.socketOption(
                .so_reuseaddr
            ),
            value: 1
        )
        .childChannelInitializer { channel in
            channel.setOption(
                ChannelOptions.socketOption(
                    .tcp_nodelay
                ),
                value: 1
            )
            .flatMapError { _ in
                channel.eventLoop
                    .makeSucceededVoidFuture()
            }
            .flatMap {
                channel.pipeline.addHandler(
                    CustomHTTP1BenchmarkHandler(
                        allocator:
                            channel.allocator
                    )
                )
            }
        }

do {
    let channel =
        try bootstrap
            .bind(
                host: host,
                port: port
            )
            .wait()

    try channel.closeFuture.wait()
    try group.syncShutdownGracefully()
} catch {
    try? group.syncShutdownGracefully()
    throw error
}
