import Foundation
import NIOCore
import NIOHTTP1

public enum RequestDecodingError: Error, Sendable {
    case emptyBody
}

public struct Request: @unchecked Sendable {
    public let method: HTTPMethod
    public let uri: String
    public let headers: HTTPHeaders
    public let body: ByteBuffer

    internal var routeParameterNames: RouteParameterNames
    internal var routeParameterRanges: RouteParameterRanges

    init(head: HTTPRequestHead, body: ByteBuffer) {
        self.init(
            head: head,
            method: HTTPMethod(head.method),
            body: body
        )
    }

    init(
        head: HTTPRequestHead,
        method: HTTPMethod,
        body: ByteBuffer
    ) {
        self.method = method
        self.uri = head.uri
        self.headers = head.headers
        self.body = body
        self.routeParameterNames = .none
        self.routeParameterRanges = .none
    }

    public var path: String {
        let bytes = uri.utf8

        guard let queryIndex = bytes.firstIndex(of: 63) else {
            return uri
        }

        return String(
            decoding: bytes[..<queryIndex],
            as: UTF8.self
        )
    }

    public var queryString: String? {
        let bytes = uri.utf8

        guard let queryIndex = bytes.firstIndex(of: 63) else {
            return nil
        }

        let start = bytes.index(after: queryIndex)

        return String(
            decoding: bytes[start...],
            as: UTF8.self
        )
    }

    public var parameters: [String: String] {
        guard !routeParameterNames.isEmpty else {
            return [:]
        }

        var values: [String: String] = [:]
        values.reserveCapacity(routeParameterNames.count)

        for index in 0..<routeParameterNames.count {
            values[routeParameterNames[index]] = decodeParameter(
                in: routeParameterRanges[index]
            )
        }

        return values
    }

    public var queryParameters: [String: String] {
        var result: [String: String] = [:]

        scanQuery { key, value in
            result[
                URLComponentDecoder.decode(
                    key,
                    plusAsSpace: true
                )
            ] = URLComponentDecoder.decode(
                value,
                plusAsSpace: true
            )

            return true
        }

        return result
    }

    public func parameter(_ name: String) -> String? {
        for index in 0..<routeParameterNames.count
        where routeParameterNames[index] == name {
            return decodeParameter(
                in: routeParameterRanges[index]
            )
        }

        return nil
    }

    public func query(_ name: String) -> String? {
        var result: String?

        scanQuery { key, value in
            guard URLComponentDecoder.equalsDecoded(
                key,
                name.utf8,
                plusAsSpace: true
            ) else {
                return true
            }

            result = URLComponentDecoder.decode(
                value,
                plusAsSpace: true
            )
            return false
        }

        return result
    }

    public func header(_ name: String) -> String? {
        headers.first(name: name)
    }

    public func cookie(_ name: String) -> String? {
        guard let header = headers.first(name: "cookie") else {
            return nil
        }

        let bytes = header.utf8
        let expected = name.utf8
        var cursor = bytes.startIndex

        while cursor != bytes.endIndex {
            while
                cursor != bytes.endIndex,
                bytes[cursor] == 32
                || bytes[cursor] == 9
                || bytes[cursor] == 59
            {
                bytes.formIndex(after: &cursor)
            }

            let keyStart = cursor

            while
                cursor != bytes.endIndex,
                bytes[cursor] != 61,
                bytes[cursor] != 59
            {
                bytes.formIndex(after: &cursor)
            }

            var keyEnd = cursor

            while
                keyEnd != keyStart
            {
                let previous = bytes.index(before: keyEnd)
                let byte = bytes[previous]

                guard byte == 32 || byte == 9 else {
                    break
                }

                keyEnd = previous
            }

            guard
                cursor != bytes.endIndex,
                bytes[cursor] == 61
            else {
                while
                    cursor != bytes.endIndex,
                    bytes[cursor] != 59
                {
                    bytes.formIndex(after: &cursor)
                }
                continue
            }

            bytes.formIndex(after: &cursor)

            let valueStart = cursor

            while
                cursor != bytes.endIndex,
                bytes[cursor] != 59
            {
                bytes.formIndex(after: &cursor)
            }

            var valueEnd = cursor

            while
                valueEnd != valueStart
            {
                let previous = bytes.index(before: valueEnd)
                let byte = bytes[previous]

                guard byte == 32 || byte == 9 else {
                    break
                }

                valueEnd = previous
            }

            if RouterByteEquality.equals(
                bytes[keyStart..<keyEnd],
                expected
            ) {
                return String(
                    decoding: bytes[valueStart..<valueEnd],
                    as: UTF8.self
                )
            }
        }

        return nil
    }

    public var bodyString: String? {
        body.getString(
            at: body.readerIndex,
            length: body.readableBytes
        )
    }

    public func decodeJSON<T: Decodable>(
        _ type: T.Type = T.self,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        guard body.readableBytes > 0 else {
            throw RequestDecodingError.emptyBody
        }

        let bytes = body.readableBytesView
        let data = Data(bytes)

        return try decoder.decode(
            type,
            from: data
        )
    }

    internal var routingBytes: String.UTF8View {
        uri.utf8
    }

    private func decodeParameter(
        in range: Range<Int>
    ) -> String {
        let bytes = uri.utf8
        let lower = bytes.index(
            bytes.startIndex,
            offsetBy: range.lowerBound
        )
        let upper = bytes.index(
            bytes.startIndex,
            offsetBy: range.upperBound
        )

        return URLComponentDecoder.decode(
            bytes[lower..<upper],
            plusAsSpace: false
        )
    }

    private func scanQuery(
        _ visit: (
            String.UTF8View.SubSequence,
            String.UTF8View.SubSequence
        ) -> Bool
    ) {
        let bytes = uri.utf8

        guard let queryIndex = bytes.firstIndex(of: 63) else {
            return
        }

        var cursor = bytes.index(after: queryIndex)

        while cursor != bytes.endIndex {
            if bytes[cursor] == 38 {
                bytes.formIndex(after: &cursor)
                continue
            }

            let keyStart = cursor

            while
                cursor != bytes.endIndex,
                bytes[cursor] != 61,
                bytes[cursor] != 38
            {
                bytes.formIndex(after: &cursor)
            }

            let keyEnd = cursor
            var valueStart = cursor

            if
                cursor != bytes.endIndex,
                bytes[cursor] == 61
            {
                bytes.formIndex(after: &cursor)
                valueStart = cursor

                while
                    cursor != bytes.endIndex,
                    bytes[cursor] != 38
                {
                    bytes.formIndex(after: &cursor)
                }
            }

            let key = bytes[keyStart..<keyEnd]
            let value = bytes[valueStart..<cursor]

            if !visit(key, value) {
                return
            }

            if
                cursor != bytes.endIndex,
                bytes[cursor] == 38
            {
                bytes.formIndex(after: &cursor)
            }
        }
    }
}
