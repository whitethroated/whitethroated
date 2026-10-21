import Foundation
import NIOCore
import WhiteThroated

public struct AuthPrincipal:
    Sendable,
    Equatable
{
    public let id: String
    public let roles: Set<String>
    public let permissions: Set<String>

    public init(
        id: String,
        roles: Set<String> = [],
        permissions: Set<String> = []
    ) {
        precondition(
            !id.isEmpty,
            "Principal id must not be empty"
        )

        self.id = id
        self.roles = roles
        self.permissions = permissions
    }
}

public enum Credential:
    Sendable,
    Equatable
{
    case bearer(String)
    case apiKey(String)
    case session(String)
    case custom(
        scheme: String,
        value: String
    )
}

public struct Authenticator: Sendable {
    public typealias Extractor =
        @Sendable (Request) -> Credential?
    public typealias Resolver =
        @Sendable (
            Credential,
            Request
        ) -> AuthPrincipal?

    public let extractor: Extractor
    public let resolver: Resolver

    public init(
        extractor: @escaping Extractor,
        resolver: @escaping Resolver
    ) {
        self.extractor = extractor
        self.resolver = resolver
    }

    public func authenticate(
        _ request: Request
    ) -> AuthPrincipal? {
        guard
            let credential =
                extractor(request)
        else {
            return nil
        }

        return resolver(
            credential,
            request
        )
    }

    public func middleware()
        -> FastMiddleware
    {
        { request, _, next in
            guard
                self.authenticate(request)
                    != nil
            else {
                return .response(
                    Self.unauthorized()
                )
            }

            return next(request)
        }
    }

    public static func bearer(
        _ resolver:
            @escaping @Sendable (
                String,
                Request
            ) -> AuthPrincipal?
    ) -> Authenticator {
        Authenticator(
            extractor: {
                request in

                guard
                    let raw =
                        request.header(
                            "authorization"
                        ),
                    let token =
                        parseBearer(raw)
                else {
                    return nil
                }

                return .bearer(token)
            },
            resolver: {
                credential,
                request in

                guard case
                    .bearer(let token) =
                        credential
                else {
                    return nil
                }

                return resolver(
                    token,
                    request
                )
            }
        )
    }

    public static func apiKey(
        header: String = "x-api-key",
        _ resolver:
            @escaping @Sendable (
                String,
                Request
            ) -> AuthPrincipal?
    ) -> Authenticator {
        Authenticator(
            extractor: {
                request in

                guard
                    let value =
                        request.header(header),
                    !value.isEmpty
                else {
                    return nil
                }

                return .apiKey(value)
            },
            resolver: {
                credential,
                request in

                guard case
                    .apiKey(let key) =
                        credential
                else {
                    return nil
                }

                return resolver(
                    key,
                    request
                )
            }
        )
    }

    private static func parseBearer(
        _ value: String
    ) -> String? {
        let prefix = "Bearer "

        guard
            value.count > prefix.count,
            value.prefix(prefix.count)
                .caseInsensitiveCompare(
                    prefix
                ) == .orderedSame
        else {
            return nil
        }

        let token =
            String(
                value.dropFirst(
                    prefix.count
                )
            )

        return token.isEmpty
            ? nil
            : token
    }

    static func unauthorized()
        -> Response
    {
        Response.text(
            "Unauthorized",
            status: .unauthorized
        )
        .header(
            "www-authenticate",
            "Bearer"
        )
    }
}

public struct EventLoopAuthenticator:
    Sendable
{
    public typealias Resolver =
        @Sendable (
            Request,
            Context
        ) -> EventLoopFuture<
            AuthPrincipal?
        >

    private let resolver: Resolver

    public init(
        _ resolver:
            @escaping Resolver
    ) {
        self.resolver = resolver
    }

    public func authenticate(
        _ request: Request,
        context: Context
    ) -> EventLoopFuture<
        AuthPrincipal?
    > {
        resolver(
            request,
            context
        )
        .hop(
            to: context.eventLoop
        )
    }

    public func middleware()
        -> Middleware
    {
        { request, context, next in
            self.authenticate(
                request,
                context: context
            )
            .flatMap { principal in
                guard principal != nil else {
                    return context
                        .eventLoop
                        .makeSucceededFuture(
                            Authenticator
                                .unauthorized()
                        )
                }

                return next(request)
            }
        }
    }
}

public struct AuthorizationPolicy:
    Sendable
{
    public typealias Evaluator =
        @Sendable (
            AuthPrincipal,
            Request
        ) -> Bool

    private let evaluator:
        Evaluator

    public init(
        _ evaluator:
            @escaping Evaluator
    ) {
        self.evaluator =
            evaluator
    }

    public func allows(
        principal: AuthPrincipal,
        request: Request
    ) -> Bool {
        evaluator(
            principal,
            request
        )
    }

    public static func role(
        _ role: String
    ) -> AuthorizationPolicy {
        AuthorizationPolicy {
            principal,
            _ in
            principal.roles
                .contains(role)
        }
    }

    public static func permission(
        _ permission: String
    ) -> AuthorizationPolicy {
        AuthorizationPolicy {
            principal,
            _ in
            principal.permissions
                .contains(permission)
        }
    }

    static func forbidden()
        -> Response
    {
        .text(
            "Forbidden",
            status: .forbidden
        )
    }
}

public extension Application {
    func use(
        authentication:
            Authenticator
    ) {
        useFast(
            authentication
                .middleware()
        )
    }

    func use(
        authentication:
            EventLoopAuthenticator
    ) {
        use(
            authentication
                .middleware()
        )
    }

    func on(
        _ method: HTTPMethod,
        _ path: String,
        authenticatedBy:
            Authenticator,
        authorization:
            AuthorizationPolicy? = nil,
        use handler:
            @escaping @Sendable (
                Request,
                AuthPrincipal
            ) -> Response
    ) {
        on(
            method,
            path
        ) { request in
            guard
                let principal =
                    authenticatedBy
                        .authenticate(
                            request
                        )
            else {
                return Authenticator
                    .unauthorized()
            }

            if
                let authorization,
                !authorization.allows(
                    principal:
                        principal,
                    request: request
                )
            {
                return AuthorizationPolicy
                    .forbidden()
            }

            return handler(
                request,
                principal
            )
        }
    }

    func get(
        _ path: String,
        authenticatedBy:
            Authenticator,
        authorization:
            AuthorizationPolicy? = nil,
        use handler:
            @escaping @Sendable (
                Request,
                AuthPrincipal
            ) -> Response
    ) {
        on(
            .get,
            path,
            authenticatedBy:
                authenticatedBy,
            authorization:
                authorization,
            use: handler
        )
    }

    func post(
        _ path: String,
        authenticatedBy:
            Authenticator,
        authorization:
            AuthorizationPolicy? = nil,
        use handler:
            @escaping @Sendable (
                Request,
                AuthPrincipal
            ) -> Response
    ) {
        on(
            .post,
            path,
            authenticatedBy:
                authenticatedBy,
            authorization:
                authorization,
            use: handler
        )
    }

    func authenticatedGroup(
        _ prefix: String,
        by authenticator:
            Authenticator,
        authorization:
            AuthorizationPolicy? = nil
    ) -> AuthenticatedRouteGroup {
        AuthenticatedRouteGroup(
            application: self,
            prefix: prefix,
            authenticator:
                authenticator,
            authorization:
                authorization
        )
    }
}

public struct AuthenticatedRouteGroup:
    Sendable
{
    private let application:
        Application
    public let prefix: String
    private let authenticator:
        Authenticator
    private let authorization:
        AuthorizationPolicy?

    public init(
        application: Application,
        prefix: String,
        authenticator:
            Authenticator,
        authorization:
            AuthorizationPolicy? = nil
    ) {
        self.application =
            application
        self.prefix =
            Self.normalize(
                prefix
            )
        self.authenticator =
            authenticator
        self.authorization =
            authorization
    }

    public func group(
        _ path: String,
        authorization:
            AuthorizationPolicy? = nil
    ) -> AuthenticatedRouteGroup {
        AuthenticatedRouteGroup(
            application:
                application,
            prefix: joined(path),
            authenticator:
                authenticator,
            authorization:
                authorization
                ?? self.authorization
        )
    }

    public func get(
        _ path: String,
        use handler:
            @escaping @Sendable (
                Request,
                AuthPrincipal
            ) -> Response
    ) {
        application.get(
            joined(path),
            authenticatedBy:
                authenticator,
            authorization:
                authorization,
            use: handler
        )
    }

    public func post(
        _ path: String,
        use handler:
            @escaping @Sendable (
                Request,
                AuthPrincipal
            ) -> Response
    ) {
        application.post(
            joined(path),
            authenticatedBy:
                authenticator,
            authorization:
                authorization,
            use: handler
        )
    }

    private func joined(
        _ path: String
    ) -> String {
        let normalized =
            Self.normalize(path)

        if prefix == "/" {
            return normalized
        }

        if normalized == "/" {
            return prefix
        }

        return prefix + normalized
    }

    private static func normalize(
        _ path: String
    ) -> String {
        guard !path.isEmpty else {
            return "/"
        }

        var value = path

        if !value.hasPrefix("/") {
            value = "/" + value
        }

        while
            value.count > 1,
            value.hasSuffix("/")
        {
            value.removeLast()
        }

        return value
    }
}
