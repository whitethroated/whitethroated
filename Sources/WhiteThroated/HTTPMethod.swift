import NIOHTTP1

public enum HTTPMethod: Sendable, Hashable {
    case get
    case post
    case put
    case patch
    case delete
    case head
    case options
    case connect
    case trace
    case other(String)

    internal var nioMethod: NIOHTTP1.HTTPMethod {
        switch self {
        case .get:
            return .GET
        case .post:
            return .POST
        case .put:
            return .PUT
        case .patch:
            return .PATCH
        case .delete:
            return .DELETE
        case .head:
            return .HEAD
        case .options:
            return .OPTIONS
        case .connect:
            return .CONNECT
        case .trace:
            return .TRACE
        case .other(let value):
            return .RAW(value: value)
        }
    }

    init(_ method: NIOHTTP1.HTTPMethod) {
        switch method {
        case .GET:
            self = .get
        case .POST:
            self = .post
        case .PUT:
            self = .put
        case .PATCH:
            self = .patch
        case .DELETE:
            self = .delete
        case .HEAD:
            self = .head
        case .OPTIONS:
            self = .options
        case .CONNECT:
            self = .connect
        case .TRACE:
            self = .trace
        case .RAW(let value):
            self = .other(value)
        default:
            self = .other(String(describing: method))
        }
    }
}
