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
        self.method = HTTPMethod(head.method)
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

    public func parameter(_ name: String) -> String? {
        for index in routeParameterNames.indices
        where routeParameterNames[index] == name {
            return decodeParameter(
                in: routeParameterRanges[index]
            )
        }

        return nil
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

        return String(
            decoding: bytes[lower..<upper],
            as: UTF8.self
        )
    }
}
