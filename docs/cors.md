# WhiteThroatedCORS

Status: experimental

`WhiteThroatedCORS` is an optional SwiftPM product. The core `WhiteThroated`,
`WhiteThroatedRuntime`, and `WhiteThroatedHTTP1` targets do not depend on it.

## Install and activate

Depend on the `WhiteThroatedCORS` library product, then configure it during
application setup:

```swift
import WhiteThroated
import WhiteThroatedCORS

let app = Application()

app.use(cors: CORSConfiguration(
    allowedOrigins: .exact([
        "https://app.example.com"
    ]),
    allowedMethods: [
        .get,
        .post,
    ],
    allowedHeaders: [
        "authorization",
        "content-type",
    ],
    exposedHeaders: [
        "x-request-id"
    ],
    allowCredentials: true,
    maxAge: 600
))
```

Importing the module alone changes no request behavior. Calling
`app.use(cors:)` installs one fast middleware layer globally.

## Origin policies

Three policies are available:

- `.any` accepts any origin. Without credentials it emits
  `Access-Control-Allow-Origin: *`.
- `.exact(Set<String>)` accepts only exact serialized origin values and echoes
  the accepted origin.
- `.custom` runs an explicit `@Sendable` resolver and echoes origins accepted
  by that resolver.

When credentials are enabled, `.any` echoes the request origin rather than
emitting `*`, because credentialed CORS responses cannot use wildcard
allow-origin semantics. One exception applies: the literal `null` origin —
the browser's opaque-origin marker for sandboxed frames and similar
contexts — is never echoed by `.any` when credentials are allowed. Such
requests follow the configured denial behavior (`403 Forbidden` by default),
since echoing
`Access-Control-Allow-Origin: null` alongside
`Access-Control-Allow-Credentials: true` would bless credentialed requests
from opaque origins.

Prefer an explicit origin allowlist for credentialed applications. `.exact`
and `.custom` remain explicit policy decisions, including whether to permit
an opaque origin; `.any` is not a substitute for CSRF protection.

## Denied requests

The default behavior is `.reject`, which returns `403 Forbidden` for an
origin, preflight method, or preflight header outside the configured policy.

Use `.passThrough` only when another application layer intentionally owns the
rejection decision:

```swift
CORSConfiguration(
    allowedOrigins: .exact([
        "https://app.example.com"
    ]),
    deniedRequestBehavior: .passThrough
)
```

Pass-through denial does not add CORS response headers.

## Preflight behavior

An `OPTIONS` request with `Access-Control-Request-Method` is treated as a
preflight request.

The middleware validates:

- origin policy;
- requested method against `allowedMethods`;
- every requested header against the case-insensitive `allowedHeaders` set;
- requested method and header names as HTTP tokens.

An allowed preflight short-circuits with `204 No Content`. The response may
include `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers`,
`Access-Control-Allow-Credentials`, and `Access-Control-Max-Age`.

Preflight responses vary on `Access-Control-Request-Method` and
`Access-Control-Request-Headers`. Reflected-origin responses also vary on
`Origin`.

## Request-path cost

If the module is not linked or `app.use(cors:)` is not called, core dispatch is
unchanged.

With CORS middleware active:

- requests without `Origin` immediately delegate to the next fast responder;
- allowed simple cross-origin requests add response headers;
- origin-specific response headers require converting a prepared response into a
  mutable `Response`;
- allowed preflight requests short-circuit without invoking the route handler.

This module currently makes no performance claim. Any optimization that changes
the middleware hot path must be validated against the disabled and enabled
controls described in `BENCHMARKS.md`.
