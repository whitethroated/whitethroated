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
    /// The challenge value for the `www-authenticate` response
    /// header on 401 replies, when this authenticator maps to a
    /// standard HTTP authentication scheme (`"Bearer"` for
    /// bearer credentials). Authenticators driven by headers
    /// that are not authentication schemes — for example API
    /// keys — have `nil` so 401 replies do not advertise a
    /// scheme that is not actually in use.
    public let challenge: String?

    public init(
        challenge: String? = nil,
        extractor:
            @escaping Extractor,
        resolver:
            @escaping Resolver
    ) {
        self.extractor = extractor
        self.resolver = resolver
        self.challenge = challenge
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
                    self
                        .unauthorizedResponse()
                )
            }

            return next(request)
        }
    }

    /// Builds the challenge-aware 401 response: the
    /// `www-authenticate` header is present only when this
    /// authenticator corresponds to a standard HTTP
    /// authentication scheme.
    public func unauthorizedResponse()
        -> Response
    {
        let response = Response.text(
            "Unauthorized",
            status: .unauthorized
        )

        guard let challenge else {
            return response
        }

        return response
            .header(
                "www-authenticate",
                challenge
            )
    }

    /// 401 response for authenticators that carry no challenge
    /// information.
    static func plainUnauthorized()
        -> Response
    {
        Response.text(
            "Unauthorized",
            status: .unauthorized
        )
    }

    public static func bearer(
        _ resolver:
            @escaping @Sendable (
                String,
                Request
            ) -> AuthPrincipal?
    ) -> Authenticator {
        Authenticator(
            challenge: "Bearer",
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
        // An API key header is not an HTTP authentication
        // scheme, so the authenticator carries no 401 challenge.
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
            String(
                value.prefix(
                    prefix.count
                )
            )
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
                                .plainUnauthorized()
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
                return authenticatedBy
                    .unauthorizedResponse()
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

    func on(
        _ method: HTTPMethod,
        _ path: String,
        authenticatedBy:
            EventLoopAuthenticator,
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
        ) { request, context in
            authenticatedBy
                .authenticate(
                    request,
                    context: context
                )
                .flatMap { principal in
                    guard
                        let principal
                    else {
                        return context.eventLoop
                            .makeSucceededFuture(
                                Authenticator
                                    .plainUnauthorized()
                            )
                    }

                    if
                        let authorization,
                        !authorization.allows(
                            principal:
                                principal,
                            request:
                                request
                        )
                    {
                        return context.eventLoop
                            .makeSucceededFuture(
                                AuthorizationPolicy
                                    .forbidden()
                            )
                    }

                    return context.eventLoop
                        .makeSucceededFuture(
                            handler(
                                request,
                                principal
                            )
                        )
                }
        }
    }

    func get(
        _ path: String,
        authenticatedBy:
            EventLoopAuthenticator,
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

    func post(
        _ path: String,
        authenticatedBy:
            EventLoopAuthenticator,
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
            authorization: Self
                .intersect(
                    child:
                        authorization,
                    with:
                        self
                        .authorization
                )
        )
    }

    /// Nesting an authenticated group never weakens the
    /// enclosing group: the effective policy is the
    /// conjunction of every policy between the root and the
    /// route, so a child with a broader rule cannot widen
    /// access that a parent restricts.
    private static func intersect(
        child: AuthorizationPolicy?,
        with parent:
            AuthorizationPolicy?
    ) -> AuthorizationPolicy? {
        guard let parent else {
            return child
        }

        guard let child else {
            return parent
        }

        return AuthorizationPolicy {
            principal,
            request in

            parent.allows(
                principal: principal,
                request: request
            )
                && child.allows(
                    principal:
                        principal,
                    request:
                        request
                )
        }
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
