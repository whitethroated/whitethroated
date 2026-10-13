import NIOHTTP1

public struct CookieOptions: Sendable {
    public enum SameSite: String, Sendable {
        case lax = "Lax"
        case strict = "Strict"
        case none = "None"
    }

    public var path: String?
    public var domain: String?
    public var maxAgeSeconds: Int?
    public var httpOnly: Bool
    public var secure: Bool
    public var sameSite: SameSite?

    public init(
        path: String? = nil,
        domain: String? = nil,
        maxAgeSeconds: Int? = nil,
        httpOnly: Bool = false,
        secure: Bool = false,
        sameSite: SameSite? = nil
    ) {
        self.path = path
        self.domain = domain
        self.maxAgeSeconds = maxAgeSeconds
        self.httpOnly = httpOnly
        self.secure = secure
        self.sameSite = sameSite
    }
}

internal enum CookieValidator {
    @inline(__always)
    static func isSafeToken(
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

    @inline(__always)
    static func isSafeValue(
        _ value: String
    ) -> Bool {
        for byte in value.utf8 {
            if
                byte < 32
                || byte == 59
                || byte == 127
            {
                return false
            }
        }

        return true
    }

    @inline(__always)
    static func isSafeAttribute(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        for byte in value.utf8 {
            if
                byte < 32
                || byte == 59
                || byte == 127
            {
                return false
            }
        }

        return true
    }
}

extension Response {
    public mutating func setCookie(
        _ name: String,
        value: String,
        options: CookieOptions = CookieOptions()
    ) {
        precondition(
            CookieValidator.isSafeToken(name),
            "Cookie name contains invalid characters"
        )
        precondition(
            CookieValidator.isSafeValue(value),
            "Cookie value contains invalid characters"
        )

        var serialized = "\(name)=\(value)"

        if let path = options.path {
            precondition(
                CookieValidator.isSafeAttribute(path),
                "Cookie path contains invalid characters"
            )
            serialized += "; Path=\(path)"
        }

        if let domain = options.domain {
            precondition(
                CookieValidator.isSafeAttribute(domain),
                "Cookie domain contains invalid characters"
            )
            serialized += "; Domain=\(domain)"
        }

        if let maxAgeSeconds = options.maxAgeSeconds {
            serialized += "; Max-Age=\(maxAgeSeconds)"
        }

        if options.httpOnly {
            serialized += "; HttpOnly"
        }

        if options.secure {
            serialized += "; Secure"
        }

        if let sameSite = options.sameSite {
            serialized += "; SameSite=\(sameSite.rawValue)"
        }

        headers.add(
            name: "set-cookie",
            value: serialized
        )
    }

    public mutating func clearCookie(
        _ name: String,
        path: String? = nil,
        domain: String? = nil
    ) {
        setCookie(
            name,
            value: "",
            options: CookieOptions(
                path: path,
                domain: domain,
                maxAgeSeconds: 0
            )
        )
    }
}
