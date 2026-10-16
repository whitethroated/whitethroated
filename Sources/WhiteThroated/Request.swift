import Foundation
import NIOCore
import NIOHTTP1

public enum RequestDecodingError: Error, Sendable {
    case emptyBody
}

public struct Request: @unchecked Sendable {
    private let nioMethod: NIOHTTP1.HTTPMethod

    public var method: HTTPMethod {
        HTTPMethod(nioMethod)
    }

    public let uri: String
    public let headers: HTTPHeaders
    public let body: ByteBuffer

    internal var routeParameterNames: RouteParameterNames
    internal var routeParameterRanges: RouteParameterRanges

    init(head: HTTPRequestHead, body: ByteBuffer) {
        self.init(
            head: head,
            body: body,
            routeParameterNames: .none,
            routeParameterRanges: .none
        )
    }

    init(
        head: HTTPRequestHead,
        body: ByteBuffer,
        routeParameterNames: RouteParameterNames,
        routeParameterRanges: RouteParameterRanges
    ) {
        self.nioMethod = head.method
        self.uri = head.uri
        self.headers = head.headers
        self.body = body
        self.routeParameterNames = routeParameterNames
        self.routeParameterRanges = routeParameterRanges
    }

    init(
        head: HTTPRequestHead,
        method: HTTPMethod,
        body: ByteBuffer
    ) {
        self.nioMethod = method.nioMethod
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

    public var formParameters: [String: String] {
        var result: [String: String] = [:]

        scanForm { key, value in
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
        let bytes = uri.utf8
        let expected = name.utf8

        if let result = bytes
            .withContiguousStorageIfAvailable({
                storage in

                Self.queryValue(
                    named: expected,
                    in: storage
                )
            })
        {
            return result
        }

        return Self.queryValue(
            named: expected,
            in: bytes
        )
    }

    public func form(_ name: String) -> String? {
        Self.formValue(
            named: name.utf8,
            in: body.readableBytesView
        )
    }

    public func header(_ name: String) -> String? {
        headers.first(name: name)
    }

    public func cookie(_ name: String) -> String? {
        guard let header = headers.first(
            name: "cookie"
        ) else {
            return nil
        }

        let bytes = header.utf8
        let expected = name.utf8

        if let result = bytes
            .withContiguousStorageIfAvailable({
                storage in

                Self.cookieValue(
                    named: expected,
                    in: storage
                )
            })
        {
            return result
        }

        return Self.cookieValue(
            named: expected,
            in: bytes
        )
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

    @inline(__always)
    internal var routingMethod: NIOHTTP1.HTTPMethod {
        nioMethod
    }

    internal var routingBytes: String.UTF8View {
        uri.utf8
    }

    @inline(__always)
    private func decodeParameter(
        in range: Range<Int>
    ) -> String {
        let bytes = uri.utf8

        if let decoded = bytes
            .withContiguousStorageIfAvailable({
                storage in

                URLComponentDecoder.decode(
                    storage[range],
                    plusAsSpace: false
                )
            })
        {
            return decoded
        }

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

    @inline(__always)
    private static func cookieValue<
        C: BidirectionalCollection,
        N: Collection
    >(
        named expected: N,
        in bytes: C
    ) -> String?
    where C.Element == UInt8, N.Element == UInt8 {
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

            while keyEnd != keyStart {
                let previous =
                    bytes.index(before: keyEnd)
                let byte = bytes[previous]

                guard
                    byte == 32
                    || byte == 9
                else {
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

            while
                cursor != bytes.endIndex,
                bytes[cursor] == 32
                || bytes[cursor] == 9
            {
                bytes.formIndex(after: &cursor)
            }

            let valueStart = cursor

            while
                cursor != bytes.endIndex,
                bytes[cursor] != 59
            {
                bytes.formIndex(after: &cursor)
            }

            var valueEnd = cursor

            while valueEnd != valueStart {
                let previous =
                    bytes.index(before: valueEnd)
                let byte = bytes[previous]

                guard
                    byte == 32
                    || byte == 9
                else {
                    break
                }

                valueEnd = previous
            }

            if RouterByteEquality.equals(
                bytes[keyStart..<keyEnd],
                expected
            ) {
                return String(
                    decoding:
                        bytes[valueStart..<valueEnd],
                    as: UTF8.self
                )
            }
        }

        return nil
    }

    @inline(__always)
    private static func queryValue<
        C: Collection,
        N: Collection
    >(
        named expected: N,
        in bytes: C
    ) -> String?
    where C.Element == UInt8, N.Element == UInt8 {
        guard let queryIndex = bytes.firstIndex(of: 63) else {
            return nil
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

            if URLComponentDecoder.equalsDecoded(
                bytes[keyStart..<keyEnd],
                expected,
                plusAsSpace: true
            ) {
                return URLComponentDecoder.decode(
                    bytes[valueStart..<cursor],
                    plusAsSpace: true
                )
            }

            if
                cursor != bytes.endIndex,
                bytes[cursor] == 38
            {
                bytes.formIndex(after: &cursor)
            }
        }

        return nil
    }

    @inline(__always)
    private static func formValue<
        C: Collection,
        N: Collection
    >(
        named expected: N,
        in bytes: C
    ) -> String?
    where C.Element == UInt8, N.Element == UInt8 {
        var cursor = bytes.startIndex

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

            if URLComponentDecoder.equalsDecoded(
                bytes[keyStart..<keyEnd],
                expected,
                plusAsSpace: true
            ) {
                return URLComponentDecoder.decode(
                    bytes[valueStart..<cursor],
                    plusAsSpace: true
                )
            }

            if
                cursor != bytes.endIndex,
                bytes[cursor] == 38
            {
                bytes.formIndex(after: &cursor)
            }
        }

        return nil
    }

    private func scanForm(
        _ visit: (
            ByteBufferView.SubSequence,
            ByteBufferView.SubSequence
        ) -> Bool
    ) {
        let bytes = body.readableBytesView
        var cursor = bytes.startIndex

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

            if !visit(
                bytes[keyStart..<keyEnd],
                bytes[valueStart..<cursor]
            ) {
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
