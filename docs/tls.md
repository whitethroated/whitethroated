# WhiteThroatedTLS

Status: **experimental**

`WhiteThroatedTLS` provides opt-in direct TLS for applications that terminate
TLS inside WhiteThroated instead of at a reverse proxy. It uses Apple's
`swift-nio-ssl` package and does not modify the core request path.

## Setup

```swift
import WhiteThroated
import WhiteThroatedTLS

let app = Application()

let tls = try DirectTLS(
    certificateChainPEMFile: "/run/secrets/tls.crt",
    privateKeyPEMFile: "/run/secrets/tls.key"
)

app.use(directTLS: tls)

try app.run(
    host: "0.0.0.0",
    port: 8443
)
```

The certificate chain, private key, and `NIOSSLContext` are loaded during
application setup. Context construction can perform blocking file I/O and must
not be moved into an event-loop callback.

The default minimum protocol version is TLS 1.2. TLS 1.3 can be required
explicitly. Renegotiation is disabled. The default ALPN list contains only
`http/1.1`, because the current WhiteThroated server transport is HTTP/1.1.

Applications can also construct `DirectTLS` from already-loaded PEM bytes to
keep secret-file ownership outside the framework.

## Reverse-proxy termination

Direct TLS is optional. A deployment may keep WhiteThroated on plain HTTP behind
a trusted reverse proxy instead. Forwarded scheme/client information remains
subject to WhiteThroated's explicit `TrustedProxy` policy; enabling TLS at a
proxy does not make forwarded headers trusted automatically.

## Certificate rotation

This experimental slice creates one immutable `NIOSSLContext` during setup.
Certificate rotation therefore requires constructing a new application/TLS
configuration and performing a controlled restart or rollout. Hot in-process
context replacement is intentionally not hidden behind mutable global state.

## Security boundary

- No trust-all client-verification mode is installed by WhiteThroated.
- Server certificates and keys are supplied explicitly by the application.
- The default minimum version is TLS 1.2.
- ALPN identifiers are validated as non-empty ASCII values no longer than 255
  bytes before NIOSSL sees them.
- The TLS handler is inserted before the HTTP pipeline.
- Core-only applications do not link `swift-nio-ssl` and do not run TLS setup.

`swift-nio-ssl` 2.37.5 is pinned exactly. It is an Apple SwiftNIO project and
fits the repository's Tier 1/fundamental dependency rule.
