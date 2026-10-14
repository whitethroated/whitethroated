import Foundation
import NIOCore
import NIOHTTP1

public struct MultipartFormDataLimits: Sendable {
    public var maxParts: Int
    public var maxHeadersPerPart: Int
    public var maxHeaderBytesPerPart: Int

    public init(
        maxParts: Int = 128,
        maxHeadersPerPart: Int = 32,
        maxHeaderBytesPerPart: Int = 16 * 1024
    ) {
        precondition(
            maxParts > 0,
            "maxParts must be greater than zero"
        )
        precondition(
            maxHeadersPerPart > 0,
            "maxHeadersPerPart must be greater than zero"
        )
        precondition(
            maxHeaderBytesPerPart > 0,
            "maxHeaderBytesPerPart must be greater than zero"
        )

        self.maxParts = maxParts
        self.maxHeadersPerPart = maxHeadersPerPart
        self.maxHeaderBytesPerPart =
            maxHeaderBytesPerPart
    }
}

public enum MultipartFormDataError:
    Error,
    Sendable,
    Equatable
{
    case invalidContentType
    case missingBoundary
    case invalidBoundary
    case invalidOpeningBoundary
    case headerBlockTooLarge(limit: Int)
    case tooManyHeaders(limit: Int)
    case tooManyParts(limit: Int)
    case malformedHeader(String)
    case missingContentDisposition
    case invalidContentDisposition
    case missingPartName
    case unexpectedEnd
}

public struct MultipartPart: Sendable {
    public let headers: HTTPHeaders
    public let name: String
    public let filename: String?

    public var contentType: String? {
        headers.first(name: "content-type")
    }

    internal init(
        headers: HTTPHeaders,
        name: String,
        filename: String?
    ) {
        self.headers = headers
        self.name = name
        self.filename = filename
    }
}

public enum MultipartFormDataEvent: Sendable {
    case partBegin(MultipartPart)
    case partBody(ByteBuffer)
    case partEnd
}

public final class MultipartFormDataParser:
    @unchecked Sendable
{
    public typealias EventHandler = (
        MultipartFormDataEvent
    ) -> Void

    private enum State {
        case openingBoundary
        case headers
        case body
        case finished
        case failed
    }

    private enum BoundarySearch {
        case found(
            index: Int,
            isFinal: Bool
        )
        case incomplete(index: Int)
        case none
    }

    private static let carriageReturn: UInt8 = 13
    private static let lineFeed: UInt8 = 10
    private static let hyphen: UInt8 = 45
    private static let colon: UInt8 = 58

    private let limits: MultipartFormDataLimits
    private let openingBoundary: [UInt8]
    private let bodyBoundary: [UInt8]
    private var state: State = .openingBoundary
    private var buffer =
        ByteBufferAllocator().buffer(capacity: 0)
    private var partCount = 0

    public convenience init(
        request: StreamRequest,
        limits: MultipartFormDataLimits =
            MultipartFormDataLimits()
    ) throws {
        guard let contentType =
            request.header("content-type")
        else {
            throw MultipartFormDataError
                .invalidContentType
        }

        try self.init(
            contentType: contentType,
            limits: limits
        )
    }

    public convenience init(
        contentType: String,
        limits: MultipartFormDataLimits =
            MultipartFormDataLimits()
    ) throws {
        let boundary = try Self.boundary(
            from: contentType
        )

        try self.init(
            boundary: boundary,
            limits: limits
        )
    }

    public init(
        boundary: String,
        limits: MultipartFormDataLimits =
            MultipartFormDataLimits()
    ) throws {
        guard Self.isValidBoundary(boundary) else {
            throw MultipartFormDataError
                .invalidBoundary
        }

        let boundaryBytes = Array(boundary.utf8)

        self.limits = limits
        self.openingBoundary =
            [Self.hyphen, Self.hyphen]
            + boundaryBytes
        self.bodyBoundary = [
            Self.carriageReturn,
            Self.lineFeed,
            Self.hyphen,
            Self.hyphen
        ] + boundaryBytes
    }

    public var isFinished: Bool {
        if case .finished = state {
            return true
        }

        return false
    }

    public func receive(
        _ chunk: ByteBuffer,
        onEvent: EventHandler
    ) throws {
        switch state {
        case .finished:
            return
        case .failed:
            throw MultipartFormDataError
                .unexpectedEnd
        default:
            break
        }

        append(chunk)

        do {
            try process(onEvent: onEvent)
        } catch {
            state = .failed
            throw error
        }
    }

    public func finish(
        onEvent: EventHandler = { _ in }
    ) throws {
        if case .finished = state {
            return
        }

        if case .failed = state {
            throw MultipartFormDataError
                .unexpectedEnd
        }

        do {
            try process(onEvent: onEvent)

            guard case .finished = state else {
                throw MultipartFormDataError
                    .unexpectedEnd
            }
        } catch {
            state = .failed
            throw error
        }
    }

    public static func boundary(
        from contentType: String
    ) throws -> String {
        guard let parsed =
            MultipartHeaderValue.parse(contentType)
        else {
            throw MultipartFormDataError
                .invalidContentType
        }

        guard
            parsed.token.lowercased()
            == "multipart/form-data"
        else {
            throw MultipartFormDataError
                .invalidContentType
        }

        guard let boundary =
            parsed.parameters["boundary"]
        else {
            throw MultipartFormDataError
                .missingBoundary
        }

        guard isValidBoundary(boundary) else {
            throw MultipartFormDataError
                .invalidBoundary
        }

        return boundary
    }

    private func append(_ chunk: ByteBuffer) {
        guard chunk.readableBytes > 0 else {
            return
        }

        if buffer.readableBytes == 0 {
            buffer = chunk
            return
        }

        if buffer.readerIndex > 0 {
            buffer.discardReadBytes()
        }

        var chunk = chunk
        buffer.writeBuffer(&chunk)
    }

    private func process(
        onEvent: EventHandler
    ) throws {
        while true {
            switch state {
            case .openingBoundary:
                guard try consumeOpeningBoundary()
                else {
                    return
                }

            case .headers:
                guard try consumeHeaders(
                    onEvent: onEvent
                ) else {
                    return
                }

            case .body:
                guard try consumeBody(
                    onEvent: onEvent
                ) else {
                    return
                }

            case .finished:
                return

            case .failed:
                throw MultipartFormDataError
                    .unexpectedEnd
            }
        }
    }

    private func consumeOpeningBoundary()
        throws -> Bool
    {
        let required =
            openingBoundary.count + 2

        guard buffer.readableBytes >= required else {
            return false
        }

        guard matches(
            openingBoundary,
            at: buffer.readerIndex
        ) else {
            throw MultipartFormDataError
                .invalidOpeningBoundary
        }

        buffer.moveReaderIndex(
            forwardBy: openingBoundary.count
        )

        let first = buffer.getInteger(
            at: buffer.readerIndex,
            as: UInt8.self
        )
        let second = buffer.getInteger(
            at: buffer.readerIndex + 1,
            as: UInt8.self
        )

        if
            first == Self.hyphen,
            second == Self.hyphen
        {
            buffer.moveReaderIndex(forwardBy: 2)
            state = .finished
            return true
        }

        guard
            first == Self.carriageReturn,
            second == Self.lineFeed
        else {
            throw MultipartFormDataError
                .invalidOpeningBoundary
        }

        buffer.moveReaderIndex(forwardBy: 2)
        state = .headers
        return true
    }

    private func consumeHeaders(
        onEvent: EventHandler
    ) throws -> Bool {
        guard let separatorIndex =
            headerSeparatorIndex()
        else {
            if buffer.readableBytes
                > limits.maxHeaderBytesPerPart + 3
            {
                throw MultipartFormDataError
                    .headerBlockTooLarge(
                        limit:
                            limits
                                .maxHeaderBytesPerPart
                    )
            }

            return false
        }

        let headerBytes =
            separatorIndex - buffer.readerIndex

        guard
            headerBytes
            <= limits.maxHeaderBytesPerPart
        else {
            throw MultipartFormDataError
                .headerBlockTooLarge(
                    limit:
                        limits
                            .maxHeaderBytesPerPart
                )
        }

        guard let headerBuffer =
            buffer.readSlice(
                length: headerBytes
            )
        else {
            return false
        }

        buffer.moveReaderIndex(forwardBy: 4)

        partCount += 1

        guard partCount <= limits.maxParts else {
            throw MultipartFormDataError
                .tooManyParts(
                    limit: limits.maxParts
                )
        }

        let part = try parsePart(
            headerBuffer
        )

        onEvent(.partBegin(part))
        state = .body
        return true
    }

    private func consumeBody(
        onEvent: EventHandler
    ) throws -> Bool {
        switch findBoundary() {
        case .found(
            let index,
            let isFinal
        ):
            let bodyBytes =
                index - buffer.readerIndex

            if bodyBytes > 0 {
                guard let slice =
                    buffer.readSlice(
                        length: bodyBytes
                    )
                else {
                    return false
                }

                onEvent(.partBody(slice))
            }

            buffer.moveReaderIndex(
                forwardBy: bodyBoundary.count + 2
            )

            onEvent(.partEnd)

            state =
                isFinal
                ? .finished
                : .headers

            return true

        case .incomplete(let index):
            let bodyBytes =
                index - buffer.readerIndex

            if bodyBytes > 0 {
                guard let slice =
                    buffer.readSlice(
                        length: bodyBytes
                    )
                else {
                    return false
                }

                onEvent(.partBody(slice))
            }

            compactTail()
            return false

        case .none:
            let retainedBytes =
                bodyBoundary.count + 1
            let bodyBytes =
                buffer.readableBytes
                - retainedBytes

            guard bodyBytes > 0 else {
                return false
            }

            guard let slice =
                buffer.readSlice(
                    length: bodyBytes
                )
            else {
                return false
            }

            onEvent(.partBody(slice))
            compactTail()
            return false
        }
    }

    private func parsePart(
        _ headerBuffer: ByteBuffer
    ) throws -> MultipartPart {
        let headerText = String(
            decoding:
                headerBuffer.readableBytesView,
            as: UTF8.self
        )

        var headers = HTTPHeaders()
        var headerCount = 0

        if !headerText.isEmpty {
            for line in headerText.components(
                separatedBy: "\r\n"
            ) {
                guard
                    !line.isEmpty,
                    line.first != " ",
                    line.first != "\t",
                    let colonIndex =
                        line.firstIndex(of: ":")
                else {
                    throw MultipartFormDataError
                        .malformedHeader(line)
                }

                let name = String(
                    line[..<colonIndex]
                )

                guard
                    !name.isEmpty,
                    Self.isHTTPToken(name)
                else {
                    throw MultipartFormDataError
                        .malformedHeader(line)
                }

                let rawValue = line[
                    line.index(after: colonIndex)...
                ]
                let value =
                    rawValue.trimmingCharacters(
                        in: .whitespaces
                    )

                headerCount += 1

                guard
                    headerCount
                    <= limits.maxHeadersPerPart
                else {
                    throw MultipartFormDataError
                        .tooManyHeaders(
                            limit:
                                limits
                                    .maxHeadersPerPart
                        )
                }

                headers.add(
                    name: name,
                    value: value
                )
            }
        }

        let dispositions =
            headers["content-disposition"]

        guard dispositions.count == 1 else {
            if dispositions.isEmpty {
                throw MultipartFormDataError
                    .missingContentDisposition
            }

            throw MultipartFormDataError
                .invalidContentDisposition
        }

        guard let disposition =
            MultipartHeaderValue.parse(
                dispositions[0]
            ),
            disposition.token.lowercased()
                == "form-data"
        else {
            throw MultipartFormDataError
                .invalidContentDisposition
        }

        guard
            let name =
                disposition.parameters["name"],
            !name.isEmpty
        else {
            throw MultipartFormDataError
                .missingPartName
        }

        return MultipartPart(
            headers: headers,
            name: name,
            filename:
                disposition.parameters["filename"]
        )
    }

    private func headerSeparatorIndex() -> Int? {
        let bytes = buffer.readableBytesView

        guard bytes.count >= 4 else {
            return nil
        }

        var index = bytes.startIndex
        let finalStart = bytes.endIndex - 3

        while index < finalStart {
            if
                bytes[index]
                    == Self.carriageReturn,
                bytes[index + 1]
                    == Self.lineFeed,
                bytes[index + 2]
                    == Self.carriageReturn,
                bytes[index + 3]
                    == Self.lineFeed
            {
                return index
            }

            index += 1
        }

        return nil
    }

    private func findBoundary() -> BoundarySearch {
        let bytes = buffer.readableBytesView
        let patternCount = bodyBoundary.count

        guard bytes.count >= patternCount else {
            return .none
        }

        var index = bytes.startIndex
        let lastPatternStart =
            bytes.endIndex - patternCount

        while index <= lastPatternStart {
            guard
                bytes[index]
                == Self.carriageReturn
            else {
                index += 1
                continue
            }

            guard matches(
                bodyBoundary,
                at: index
            ) else {
                index += 1
                continue
            }

            let suffixIndex =
                index + patternCount
            let suffixBytes =
                bytes.endIndex - suffixIndex

            guard suffixBytes >= 2 else {
                return .incomplete(
                    index: index
                )
            }

            let first = bytes[suffixIndex]
            let second = bytes[suffixIndex + 1]

            if
                first == Self.hyphen,
                second == Self.hyphen
            {
                return .found(
                    index: index,
                    isFinal: true
                )
            }

            if
                first == Self.carriageReturn,
                second == Self.lineFeed
            {
                return .found(
                    index: index,
                    isFinal: false
                )
            }

            index += 1
        }

        return .none
    }

    @inline(__always)
    private func matches(
        _ pattern: [UInt8],
        at index: Int
    ) -> Bool {
        let bytes = buffer.readableBytesView

        guard
            index >= bytes.startIndex,
            index + pattern.count
                <= bytes.endIndex
        else {
            return false
        }

        for offset in 0..<pattern.count
        where bytes[index + offset]
            != pattern[offset]
        {
            return false
        }

        return true
    }

    private func compactTail() {
        guard buffer.readerIndex > 0 else {
            return
        }

        buffer.discardReadBytes()
    }

    private static func isValidBoundary(
        _ boundary: String
    ) -> Bool {
        let bytes = boundary.utf8

        guard
            !bytes.isEmpty,
            bytes.count <= 70,
            bytes.last != 32
        else {
            return false
        }

        for byte in bytes {
            switch byte {
            case 32,
                 39,
                 40...41,
                 43...47,
                 48...57,
                 58,
                 61,
                 63,
                 65...90,
                 95,
                 97...122:
                continue

            default:
                return false
            }
        }

        return true
    }

    private static func isHTTPToken(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        for byte in value.utf8 {
            switch byte {
            case 33,
                 35...39,
                 42...43,
                 45...46,
                 48...57,
                 65...90,
                 94...96,
                 97...122,
                 124,
                 126:
                continue

            default:
                return false
            }
        }

        return true
    }
}

private enum MultipartHeaderValue {
    struct Parsed {
        let token: String
        let parameters: [String: String]
    }

    static func parse(
        _ value: String
    ) -> Parsed? {
        let bytes = Array(value.utf8)
        var index = 0

        skipWhitespace(
            bytes,
            index: &index
        )

        let tokenStart = index

        while
            index < bytes.count,
            bytes[index] != 59
        {
            index += 1
        }

        let tokenEnd =
            trimEnd(
                bytes,
                start: tokenStart,
                end: index
            )

        guard tokenEnd > tokenStart else {
            return nil
        }

        let token = String(
            decoding:
                bytes[tokenStart..<tokenEnd],
            as: UTF8.self
        )

        var parameters: [String: String] = [:]

        while index < bytes.count {
            guard bytes[index] == 59 else {
                return nil
            }

            index += 1

            skipWhitespace(
                bytes,
                index: &index
            )

            if index == bytes.count {
                break
            }

            let nameStart = index

            while
                index < bytes.count,
                bytes[index] != 61,
                bytes[index] != 59
            {
                index += 1
            }

            let nameEnd =
                trimEnd(
                    bytes,
                    start: nameStart,
                    end: index
                )

            guard
                nameEnd > nameStart,
                index < bytes.count,
                bytes[index] == 61
            else {
                return nil
            }

            let name = String(
                decoding:
                    bytes[nameStart..<nameEnd],
                as: UTF8.self
            ).lowercased()

            index += 1

            skipWhitespace(
                bytes,
                index: &index
            )

            guard index <= bytes.count else {
                return nil
            }

            let parameterValue: String

            if
                index < bytes.count,
                bytes[index] == 34
            {
                index += 1
                var decoded: [UInt8] = []
                var closed = false

                while index < bytes.count {
                    let byte = bytes[index]

                    if byte == 34 {
                        index += 1
                        closed = true
                        break
                    }

                    if byte == 92 {
                        index += 1

                        guard index < bytes.count else {
                            return nil
                        }

                        decoded.append(bytes[index])
                        index += 1
                        continue
                    }

                    decoded.append(byte)
                    index += 1
                }

                guard closed else {
                    return nil
                }

                parameterValue = String(
                    decoding: decoded,
                    as: UTF8.self
                )

                skipWhitespace(
                    bytes,
                    index: &index
                )

                guard
                    index == bytes.count
                    || bytes[index] == 59
                else {
                    return nil
                }
            } else {
                let valueStart = index

                while
                    index < bytes.count,
                    bytes[index] != 59
                {
                    index += 1
                }

                let valueEnd =
                    trimEnd(
                        bytes,
                        start: valueStart,
                        end: index
                    )

                parameterValue = String(
                    decoding:
                        bytes[valueStart..<valueEnd],
                    as: UTF8.self
                )
            }

            guard parameters[name] == nil else {
                return nil
            }

            parameters[name] = parameterValue
        }

        return Parsed(
            token: token.trimmingCharacters(
                in: .whitespaces
            ),
            parameters: parameters
        )
    }

    private static func skipWhitespace(
        _ bytes: [UInt8],
        index: inout Int
    ) {
        while
            index < bytes.count,
            bytes[index] == 32
            || bytes[index] == 9
        {
            index += 1
        }
    }

    private static func trimEnd(
        _ bytes: [UInt8],
        start: Int,
        end: Int
    ) -> Int {
        var end = end

        while
            end > start,
            bytes[end - 1] == 32
            || bytes[end - 1] == 9
        {
            end -= 1
        }

        return end
    }
}


extension StreamRequest {
    public func multipartParser(
        limits: MultipartFormDataLimits =
            MultipartFormDataLimits()
    ) throws -> MultipartFormDataParser {
        try MultipartFormDataParser(
            request: self,
            limits: limits
        )
    }
}

extension MultipartPart {
    public var isFile: Bool {
        filename != nil
    }
}
