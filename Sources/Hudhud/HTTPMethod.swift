import NIOHTTP1

public enum HTTPMethod: Sendable, Hashable {
    case get
    case post
    case put
    case patch
    case delete
    case head
    case options

    init(_ method: NIOHTTP1.HTTPMethod) {
        switch method {
        case .GET: self = .get
        case .POST: self = .post
        case .PUT: self = .put
        case .PATCH: self = .patch
        case .DELETE: self = .delete
        case .HEAD: self = .head
        case .OPTIONS: self = .options
        default: self = .get
        }
    }
}
