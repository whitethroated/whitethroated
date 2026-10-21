import Foundation
import NIOHTTP1
import WhiteThroated

public enum CORSOriginPolicy: Sendable {
    case any
    case exact(Set<String>)
    case custom(@Sendable (String) -> Bool)
}

public enum CORSDeniedRequestBehavior: Sendable {
    case reject
    case passThrough
}

public struct CORSConfiguration: Sendable {
    public let allowedOrigins: CORSOriginPolicy
    public let allowedMethods: Set<WhiteThroated.HTTPMethod>
    public let allowedHeaders: Set<String>
    public let exposedHeaders: [String]
    public let allowCredentials: Bool
    public let maxAge: Int?
    public let deniedRequestBehavior: CORSDeniedRequestBehavior

    internal let allowedMethodNames: Set<String>
    internal let allowedMethodsHeader: String
    internal let allowedHeaderNames: Set<String>
    internal let allowedHeadersHeader: String?
    internal let exposedHeadersHeader: String?

    public init(
        allowedOrigins: CORSOriginPolicy,
        allowedMethods: Set<WhiteThroated.HTTPMethod> = [
            .get,
            .head,
            .post,
        ],
        allowedHeaders: Set<String> = [],
        exposedHeaders: [String] = [],
        allowCredentials: Bool = false,
        maxAge: Int? = nil,
        deniedRequestBehavior: CORSDeniedRequestBehavior = .reject
    ) {
        if let maxAge {
            precondition(
                maxAge >= 0,
                "CORS maxAge must be zero or greater"
            )
        }

        let methodNames = Set(
            allowedMethods.map(Self.methodName)
        )
        let normalizedAllowedHeaders = Set(
            allowedHeaders.map {
                $0.lowercased()
            }
        )

        self.allowedOrigins = allowedOrigins
        self.allowedMethods = allowedMethods
        self.allowedHeaders = normalizedAllowedHeaders
        self.exposedHeaders = exposedHeaders
        self.allowCredentials = allowCredentials
        self.maxAge = maxAge
        self.deniedRequestBehavior =
            deniedRequestBehavior
        self.allowedMethodNames = methodNames
        self.allowedMethodsHeader =
            methodNames.sorted().joined(
                separator: ", "
            )
        self.allowedHeaderNames =
            normalizedAllowedHeaders

        let allowedHeaderValues =
            normalizedAllowedHeaders.sorted()
        self.allowedHeadersHeader =
            allowedHeaderValues.isEmpty
                ? nil
                : allowedHeaderValues.joined(
                    separator: ", "
                )

        self.exposedHeadersHeader =
            exposedHeaders.isEmpty
                ? nil
                : exposedHeaders.joined(
                    separator: ", "
                )
    }

    private static func methodName(
        _ method: WhiteThroated.HTTPMethod
    ) -> String {
        switch method {
        case .get:
            return "GET"
        case .post:
            return "POST"
        case .put:
            return "PUT"
        case .patch:
            return "PATCH"
        case .delete:
            return "DELETE"
        case .head:
            return "HEAD"
        case .options:
            return "OPTIONS"
        case .connect:
            return "CONNECT"
        case .trace:
            return "TRACE"
        case .other(let value):
            return value
        }
    }
}

public struct CORS: Sendable {
    public let configuration: CORSConfiguration

    public init(
        configuration: CORSConfiguration
    ) {
        self.configuration = configuration
    }

    public func middleware() -> FastMiddleware {
        { request, _, next in
            self.respond(
                to: request,
                next: next
            )
        }
    }

    internal func respond(
        to request: Request,
        next: @escaping FastNext
    ) -> MiddlewareResult {
        guard let origin = request.header("origin") else {
            return next(request)
        }

        guard
            let allowedOrigin = allowedOrigin(
                for: origin
            )
        else {
            return deniedResult(
                request: request,
                next: next,
                preflight:
                    isPreflight(request)
            )
        }

        if isPreflight(request) {
            return preflightResult(
                request: request,
                allowedOrigin: allowedOrigin,
                next: next
            )
        }

        return next(request).map { response in
            var response = response

            self.applyOriginHeaders(
                allowedOrigin,
                to: &response
            )

            if let exposed =
                configuration
                    .exposedHeadersHeader
            {
                response.headers
                    .replaceOrAdd(
                        name:
                            "access-control-expose-headers",
                        value: exposed
                    )
            }

            return response
        }
    }

    private enum AllowedOrigin: Sendable {
        case wildcard
        case echo(String)
    }

    private func allowedOrigin(
        for origin: String
    ) -> AllowedOrigin? {
        switch configuration.allowedOrigins {
        case .any:
            if configuration.allowCredentials {
                return .echo(origin)
            }

            return .wildcard

        case .exact(let origins):
            guard origins.contains(origin) else {
                return nil
            }

            return .echo(origin)

        case .custom(let resolver):
            guard resolver(origin) else {
                return nil
            }

            return .echo(origin)
        }
    }

    private func preflightResult(
        request: Request,
        allowedOrigin: AllowedOrigin,
        next: @escaping FastNext
    ) -> MiddlewareResult {
        guard
            let requestedMethodRaw =
                request.header(
                    "access-control-request-method"
                )
        else {
            return next(request)
        }

        let requestedMethod =
            requestedMethodRaw
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        guard
            Self.isHTTPToken(requestedMethod),
            configuration
                .allowedMethodNames
                .contains(requestedMethod)
        else {
            return deniedResult(
                request: request,
                next: next,
                preflight: true
            )
        }

        guard
            let requestedHeaders =
                Self.parseRequestedHeaders(
                    request.header(
                        "access-control-request-headers"
                    )
                ),
            requestedHeaders.isSubset(
                of: configuration
                    .allowedHeaderNames
            )
        else {
            return deniedResult(
                request: request,
                next: next,
                preflight: true
            )
        }

        var response = Response.noContent()

        applyOriginHeaders(
            allowedOrigin,
            to: &response
        )

        response.headers.replaceOrAdd(
            name:
                "access-control-allow-methods",
            value:
                configuration
                    .allowedMethodsHeader
        )

        if let allowedHeaders =
            configuration.allowedHeadersHeader
        {
            response.headers.replaceOrAdd(
                name:
                    "access-control-allow-headers",
                value: allowedHeaders
            )
        }

        if let maxAge = configuration.maxAge {
            response.headers.replaceOrAdd(
                name: "access-control-max-age",
                value: String(maxAge)
            )
        }

        Self.appendVary(
            [
                "Access-Control-Request-Method",
                "Access-Control-Request-Headers",
            ],
            to: &response.headers
        )

        return .response(response)
    }

    private func deniedResult(
        request: Request,
        next: @escaping FastNext,
        preflight: Bool
    ) -> MiddlewareResult {
        switch
            configuration
                .deniedRequestBehavior
        {
        case .passThrough:
            return next(request)

        case .reject:
            var response = Response.text(
                "CORS request denied",
                status: .forbidden
            )

            var vary = ["Origin"]

            if preflight {
                vary.append(
                    "Access-Control-Request-Method"
                )
                vary.append(
                    "Access-Control-Request-Headers"
                )
            }

            Self.appendVary(
                vary,
                to: &response.headers
            )

            return .response(response)
        }
    }

    private func applyOriginHeaders(
        _ allowedOrigin: AllowedOrigin,
        to response: inout Response
    ) {
        switch allowedOrigin {
        case .wildcard:
            response.headers.replaceOrAdd(
                name:
                    "access-control-allow-origin",
                value: "*"
            )

        case .echo(let origin):
            response.headers.replaceOrAdd(
                name:
                    "access-control-allow-origin",
                value: origin
            )

            Self.appendVary(
                ["Origin"],
                to: &response.headers
            )
        }

        if configuration.allowCredentials {
            response.headers.replaceOrAdd(
                name:
                    "access-control-allow-credentials",
                value: "true"
            )
        }
    }

    private func isPreflight(
        _ request: Request
    ) -> Bool {
        request.method == .options
            && request.header(
                "access-control-request-method"
            ) != nil
    }

    private static func parseRequestedHeaders(
        _ value: String?
    ) -> Set<String>? {
        guard let value else {
            return []
        }

        guard !value.isEmpty else {
            return []
        }

        var result = Set<String>()

        for part in value.split(
            separator: ",",
            omittingEmptySubsequences: false
        ) {
            let name = String(part)
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased()

            guard isHTTPToken(name) else {
                return nil
            }

            result.insert(name)
        }

        return result
    }

    private static func isHTTPToken(
        _ value: String
    ) -> Bool {
        guard !value.isEmpty else {
            return false
        }

        for byte in value.utf8 {
            switch byte {
            case 48...57,
                65...90,
                97...122,
                33,
                35...39,
                42,
                43,
                45,
                46,
                94...96,
                124,
                126:
                continue

            default:
                return false
            }
        }

        return true
    }

    private static func appendVary(
        _ names: [String],
        to headers: inout HTTPHeaders
    ) {
        let existing =
            headers.first(name: "vary")
                ?? ""
        let existingNames = Set(
            existing
                .split(separator: ",")
                .map {
                    String($0)
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )
                        .lowercased()
                }
        )

        let additions = names.filter {
            !existingNames.contains(
                $0.lowercased()
            )
        }

        guard !additions.isEmpty else {
            return
        }

        headers.add(
            name: "vary",
            value:
                additions.joined(
                    separator: ", "
                )
        )
    }
}

public extension Application {
    func use(
        cors configuration: CORSConfiguration
    ) {
        use(
            cors: CORS(
                configuration: configuration
            )
        )
    }

    func use(cors: CORS) {
        useFast(cors.middleware())
    }
}
