# WhiteThroatedWebSocket

Status: **experimental**

`WhiteThroatedWebSocket` provides RFC 6455 WebSocket endpoints through
SwiftNIO's stock HTTP/1 upgrade pipeline. Registering the capability is an
explicit application-wide setup decision; applications without it keep the
ordinary WhiteThroated transport selection and perform no upgrade bookkeeping.

## Setup

```swift
import WhiteThroated
import WhiteThroatedWebSocket

var sockets = WebSocketRouter(
    configuration: WebSocketConfiguration(
        maxFrameBytes: 16 * 1024,
        maxMessageBytes: 1024 * 1024
    )
)

try sockets.on(
    "/chat",
    configuration: WebSocketRouteConfiguration(
        subprotocols: ["chat.v1"]
    ),
    handlers: WebSocketHandlers(
        onText: { connection, text in
            _ = connection.sendText(text)
        }
    )
)

app.use(webSockets: sockets)
```

Routes are exact paths in the initial API. Query strings are ignored for route
selection. Duplicate paths and invalid subprotocol tokens are rejected during
setup.

When a WebSocket router is installed, WhiteThroated deliberately selects the
stock SwiftNIO HTTP/1 pipeline. The Tier 1 parser is not extended for WebSocket
handshakes. SwiftNIO validates the WebSocket key/version, writes the 101
response, removes HTTP codecs, and installs its frame encoder/decoder. The
WhiteThroated HTTP connection handler is removed synchronously at upgrade
completion before application WebSocket handlers receive frames.

SwiftNIO's stock server upgrade handler only attempts an upgrade on the first
HTTP request of a connection. WebSocket clients should therefore establish the
upgrade on a fresh connection, which is the normal browser/client behavior.

A refused or invalid handshake is re-delivered to ordinary HTTP routing rather
than closed without a status. A failed `onFuture` acceptance check is treated
as a refusal too. The normal HTTP route determines the response (for example,
404 for a route miss); refusal does not itself synthesize an authentication
response. Protect any corresponding HTTP route separately.

The fallback response carries `Connection: close` and the connection closes
after flushing. This also applies when no supported Upgrade protocol matches:
NIO's decoder stops parsing after an upgrade-flagged request, even when no
upgrade occurs. Keeping that connection alive would strand later requests.

## Message and control-frame behavior

- Frame size is bounded by `maxFrameBytes` in SwiftNIO's decoder.
- Fragmented text/binary messages are reassembled only up to
  `maxMessageBytes`.
- Invalid continuation ordering closes with protocol error.
- Unmasked client frames or nonzero RSV bits close with 1002; no extensions
  that authorize those reserved bits are negotiated.
- Invalid UTF-8 text closes with the WebSocket inconsistent-data code.
- Oversized messages close with 1009.
- Ping is answered with Pong carrying the same payload.
- Ping/Pong payloads are limited to 125 bytes.
- Peer close is echoed when the server has not already sent close.
- Application close waits for the peer close and has a bounded transport close
  timeout.
- `onClose` is emitted at most once.

Handlers execute on the channel event loop and must not block. Outbound
operations return `EventLoopFuture<Void>`; the module does not create a Swift
`Task` per message.

## Authentication

The WebSocket product does not depend on `WhiteThroatedAuth`. The handshake
acceptance closure receives the normal WhiteThroated `Request`, so applications
can compose an authenticator explicitly:

```swift
try sockets.on(
    "/private",
    accept: { request in
        authenticator.authenticate(request) != nil
    },
    handlers: handlers
)
```

Credentials are evaluated only during the handshake in this pattern. For an
event-loop-native authenticator or store lookup, use `onFuture`; its acceptance
future is hopped back to the connection event loop before the handshake decision:

```swift
try sockets.onFuture(
    "/private",
    accept: { request, eventLoop in
        authenticate(request, on: eventLoop)
            .map { $0 != nil }
    },
    handlers: handlers
)
```

No Swift `Task` is created by either acceptance API. If the application needs
per-message authorization, it must keep only the minimum necessary principal
state in its own connection handler state and re-evaluate policy when
appropriate.

## Observability

`WebSocketRouter.eventSink` emits bounded events using the registered route
label, message kind/byte count, negotiated subprotocol, and close code. It never
uses a raw query string, user ID, credential, or message body as a label. The
sink is generic so applications can bridge it to their logging, metrics, or
tracing backend without making observability a required WebSocket dependency.

## Compression

WebSocket per-message compression is intentionally not enabled in the initial
implementation. It remains a separate capability and must not silently change
frame semantics or memory behavior.

## Benchmark boundary

A serious benchmark must compare capability absent, capability linked but not
installed, and active upgraded connections. Active measurements must record RPS
or message throughput, p50/p90/p99/p99.999/max latency, errors, completed
messages, and peak RSS. GitHub-hosted CI is only a smoke gate, not performance
evidence.
