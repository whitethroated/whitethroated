import NIOHTTP1

public struct Response: Sendable {
    public enum Body: Sendable {
        case empty
        case text(String)
        case bytes([UInt8])
    }

    public var status: HTTPResponseStatus
    public var headers: HTTPHeaders
    public var body: Body

    public init(
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = HTTPHeaders(),
        body: Body = .empty
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/plain; charset=utf-8")

        return Response(status: status, headers: headers, body: .text(value))
    }

    public static func json(
        _ value: String,
        status: HTTPResponseStatus = .ok
    ) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json; charset=utf-8")

        return Response(status: status, headers: headers, body: .text(value))
    }

    public static func noContent() -> Response {
        Response(status: .noContent)
    }

    public static func notFound() -> Response {
        Response.text("Not Found", status: .notFound)
    }

    public static func internalServerError() -> Response {
        Response.text("Internal Server Error", status: .internalServerError)
    }
}
