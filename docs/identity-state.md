# WhiteThroated identity and state modules

Status: **experimental**

Phase 3 keeps identity and state split into independently selectable products:

- `WhiteThroatedAuth`
- `WhiteThroatedSessions`
- `WhiteThroatedRedisSessions`
- `WhiteThroatedCSRF`
- `WhiteThroatedAuthRateLimit`

## Authentication and authorization

```swift
import WhiteThroated
import WhiteThroatedAuth

let auth = Authenticator.bearer { token, _ in
    guard token == expectedToken else {
        return nil
    }

    return AuthPrincipal(
        id: "user-42",
        roles: ["admin"]
    )
}

app.get(
    "/admin",
    authenticatedBy: auth,
    authorization: .role("admin")
) { _, principal in
    .text(principal.id)
}
```

Authenticated route helpers pass `AuthPrincipal` directly to the selected handler.
They do not install a principal dictionary or identity slot into every core
`Request`. Synchronous authenticators stay synchronous. Backends that require
event-loop-native I/O use `EventLoopAuthenticator` instead of hiding a
`Task` inside the synchronous API.

Authentication failure returns 401. Authorization denial after successful
authentication returns 403.

Bearer authentication emits `WWW-Authenticate: Bearer`. API-key and custom
authenticators without a configured challenge do not advertise a Bearer
scheme. A custom synchronous authenticator can supply `challenge:` and use
`unauthorizedResponse()` for the same response as its route/middleware helpers.
The scheme-agnostic `EventLoopAuthenticator` emits no challenge by default;
applications using an HTTP authentication scheme on that tier must supply an
appropriate challenge in their response policy. A challenge-less 401 is not a
claim of full HTTP authentication-scheme compliance.

Nested authenticated groups combine parent and child authorization with AND.
A child policy cannot replace or weaken the parent's policy; omitting a child
policy preserves the parent restriction.

## Sessions

```swift
import WhiteThroatedSessions

let store = MemorySessionStore(
    maxSessions: 10_000
)

let codec = SessionCookieCodec(
    keys: [
        SessionSigningKey(
            id: "2026-10",
            secret: signingSecret
        )
    ]
)

let sessions = SessionManager(
    store: store,
    codec: codec,
    ttlSeconds: 86_400
)

let accountAuth = sessions.authenticator { session in
    session.values["role"].map {
        AuthPrincipal(
            id: session.id,
            roles: [$0]
        )
    }
}

app.get(
    "/account",
    authenticatedBy: accountAuth,
    authorization: .role("owner")
) { _, principal in
    .text(principal.id)
}
```

The event-loop authenticator resolves the principal on the channel event loop,
applies the same authorization policy, and only then invokes the synchronous
typed handler. It does not create a Swift `Task`; it stays on the future tier.
Async handlers that need the principal can call
`EventLoopAuthenticator.authenticate(_:context:)` explicitly.

Session access is explicit and lazy. A route that never calls `load`,
`persist`, `rotate`, or `destroy` does not decode a session cookie or query
a session store.

Cookie defaults are `HttpOnly`, `Secure`, `SameSite=Lax`, and path `/`.
The cookie contains an opaque session ID plus an HMAC-SHA256 signature. The
first signing key is used for new cookies; older keys remain valid for
verification during key rotation.

`Secure` is a configuration flag, not automatic HTTPS detection. Keep it enabled
in production, including behind a TLS-terminating proxy; local plain-HTTP tests
must explicitly choose their cookie policy. Never infer security from untrusted
forwarded headers.

Call `rotate` after login or any privilege elevation. Rotation deletes the old
store entry before persisting the replacement identifier.

`clearCookie` repeats the configured cookie attributes (`HttpOnly`, `Secure`,
`SameSite`, path) with an empty value and `Max-Age=0`, so the deletion matches
the original cookie on the client.

The bounded memory store is for development, tests, and single-process
deployments where process-local sessions are acceptable. It enforces TTL,
`maxSessions`, and least-recently-touched eviction.

TTL currently runs from the last explicit save. Loading a session does not
renew its TTL, and there is no separate idle-expiration policy or absolute
maximum lifetime. Those roadmap capabilities remain unimplemented.

## Redis adapter

`WhiteThroatedRedisSessions` is a separate adapter product. It uses RediStack
and stores JSON-encoded session records with Redis TTL. The adapter does not
block event-loop threads and hops completion to the event loop requested by the
session contract.

Redis availability, authentication, TLS, replication, and operational failover
remain deployment concerns. The base Sessions product does not import Redis.

## CSRF

```swift
import WhiteThroatedCSRF

let csrf = CSRFProtection(
    originPolicy: .allowed(
        ["https://app.example.com"],
        requireOriginOrReferer: true
    )
)

var session = loadedSession
let token = csrf.ensureToken(
    in: &session
)

guard csrf.validate(
    request: request,
    session: session
) else {
    return csrf.failureResponse()
}
```

Safe methods (`GET`, `HEAD`, `OPTIONS`, `TRACE`) bypass synchronizer-token
validation. Unsafe methods require the configured token header and, when an
origin policy is enabled, an allowed `Origin` or `Referer` origin.

The CSRF token is random 256-bit material stored in the server-side session.
Do not treat CORS as a replacement for CSRF protection when browser cookies are
used for authentication.

## Auth-related rate limiting

`WhiteThroatedAuthRateLimit` can derive a fixed-size HMAC key from an
authenticated principal ID and feed it into the bounded RateLimit module. This
prevents raw bearer tokens or API keys from becoming retained limiter keys.

A request that fails or omits authentication belongs to the authenticator, not
to the limiter: `AuthRateLimit.fixedWindow` passes such requests through by
default, so the authenticator's own 401/403 flow answers them instead of a
limiter 429. Deployments that must fail closed opt into
`keyFailureBehavior: .reject` on the wrapper explicitly; the wrapper's value
overrides the passed configuration's key failure behavior.

## Security boundaries

- Password hashing is intentionally not implemented here. Use a maintained
  cryptographic password-hashing adapter.
- JWT/OAuth/OIDC are separate adapters; the base Auth product does not pull
  network or cryptography dependencies for simple bearer/API-key use.
- Session signing authenticates the cookie value; it does not encrypt
  server-side session data.
- Never log raw credentials, session cookies, CSRF tokens, or signing secrets.
- Redis is a production store adapter, not a substitute for transport security
  or Redis access control.
- The experimental APIs require a security review and benchmark record before
  promotion to preview.
