import NIOCore
import NIOHTTP1

public struct Request: @unchecked Sendable {
    public let method: HTTPMethod
    public let uri: String
    public let headers: HTTPHeaders
    public let body: ByteBuffer

    internal var routeParameterNames: [String]
    internal var routeParameterRanges: [Range<Int>]

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
        self.routeParameterNames = []
        self.routeParameterRanges = []
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

        for index in routeParameterNames.indices {
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
        for index in routeParameterNames.indices
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

    public var bodyString: String? {
        body.getString(
            at: body.readerIndex,
            length: body.readableBytes
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
