public struct DatabaseError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    public enum Kind:
        String,
        Sendable
    {
        case cancelled
        case timeout
        case unavailable
        case constraint
        case syntax
        case transaction
        case mapping
        case other
    }

    public let kind: Kind
    public let message: String
    public let code: String?
    public let isTransient: Bool

    public var description: String {
        if let code {
            return "\(kind.rawValue)(\(code)): \(message)"
        }

        return "\(kind.rawValue): \(message)"
    }

    public init(
        kind: Kind,
        message: String,
        code: String? = nil,
        isTransient: Bool = false
    ) {
        self.kind = kind
        self.message = message
        self.code = code
        self.isTransient =
            isTransient
    }
}
