import NIOCore
import NIOHTTP1

public struct Request: @unchecked Sendable {
    public let method: HTTPMethod
    public let uri: String
    public let path: String
    public let headers: HTTPHeaders
    public let body: ByteBuffer
    public internal(set) var parameters: [String: String]

    init(head: HTTPRequestHead, body: ByteBuffer) {
        self.method = HTTPMethod(head.method)
        self.uri = head.uri
        self.path = Request.extractPath(from: head.uri)
        self.headers = head.headers
        self.body = body
        self.parameters = [:]
    }

    public func parameter(_ name: String) -> String? {
        parameters[name]
    }

    public func header(_ name: String) -> String? {
        headers.first(name: name)
    }

    public var bodyString: String? {
        body.getString(at: body.readerIndex, length: body.readableBytes)
    }

    private static func extractPath(from uri: String) -> String {
        guard let queryIndex = uri.firstIndex(of: "?") else {
            return uri
        }

        return String(uri[..<queryIndex])
    }
}
