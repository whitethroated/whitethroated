# WhiteThroated

WhiteThroated is an experimental high-performance web framework written entirely in Swift.

The project has two non-negotiable goals:

1. An ergonomic developer experience inspired by Express.js.
2. A low-overhead runtime architecture designed to push Swift server performance as far as practical.

WhiteThroated is pre-alpha. API compatibility is intentionally secondary to establishing a fast, measurable runtime architecture.

## Requirements

- Swift 6.4 is the development and benchmark toolchain.
- Swift Package Manager tools version 6.1 or newer.
- SwiftNIO 2.104.0, pinned exactly for reproducible builds.
- The optional PostgreSQL adapter requires the system `libpq` development
  library and `pkg-config`; the core framework does not.

## Quick start

```swift
import WhiteThroated

let app = Application()

app.get("/") { _ in
    .text("Hello from WhiteThroated")
}

app.get("/users/:id") { request in
    let id = request.parameter("id") ?? "unknown"
    let expand = request.query("expand") ?? "false"

    return .json(
        #"{"id":"\#(id)","expand":"\#(expand)"}"#
    )
}

try app.run(port: 3000)
```

## Optional modules

WhiteThroated keeps application features outside the core request path. Optional capabilities are separate SwiftPM products and do nothing unless the application imports and configures them.

The first experimental module is `WhiteThroatedCORS`:

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
    allowCredentials: true,
    maxAge: 600
))

app.get("/api/profile") { _ in
    .json(#"{"ok":true}"#)
}
```

Requests without an `Origin` header pass through without CORS response mutation. Cross-origin requests are denied by default unless their origin is allowed. Preflight requests are validated against the configured method and header allowlists. See `docs/cors.md` for the security and caching behavior.

The second experimental module is `WhiteThroatedStaticFiles`:

```swift
import WhiteThroated
import WhiteThroatedStaticFiles

let files = try await StaticFiles.open(
    directory: "./Public",
    options: .production
)

let app = Application()
app.mountStatic(
    "/assets",
    files: files
)

do {
    try app.run(port: 3000)
    try await files.close()
} catch {
    try? await files.close()
    throw error
}
```

Static files are mounted as prefix-scoped routes rather than global middleware, so unrelated routes do not perform filesystem lookup. The experimental slice supports GET/HEAD, MIME types, weak ETag/304, single byte ranges, and strict no-follow path traversal. The application explicitly owns the opened root-directory lifecycle. See `docs/static-files.md` for security, lifecycle, limitations, and benchmark status.


The third experimental module is `WhiteThroatedValidation`:

```swift
import WhiteThroated
import WhiteThroatedValidation

let schema = ValidationSchema(
    fields: [
        .path("id", rules: [.nonEmpty]),
        .query(
            "mode",
            required: false,
            rules: [.oneOf(["safe", "fast"])]
        ),
    ]
)

app.get("/users/:id") { request in
    guard
        let values = try? request
            .validate(schema)
            .get()
    else {
        return .text(
            "Invalid request",
            status: .badRequest
        )
    }

    return .text(
        values[.path, "id"] ?? ""
    )
}
```

Validation is handler-scoped rather than global middleware: routes that do not call it do not perform Validation work. The first experimental slice supports structured path/query/header/cookie string validation plus bounded, lazy Codable JSON decoding with byte and nesting-depth limits. See `docs/validation.md` for the error model, cost model, and current boundaries.


The fourth experimental module is `WhiteThroatedRateLimit`:

```swift
import WhiteThroated
import WhiteThroatedRateLimit

let limiter = FixedWindowRateLimiter(
    configuration:
        FixedWindowRateLimitConfiguration(
            limit: 100,
            windowSeconds: 60,
            maxKeys: 10_000
        ),
    keyResolver: { request in
        request.header("x-api-key")
    }
)

app.use(rateLimiter: limiter)
```

The initial RateLimit slice is a bounded in-process fixed-window limiter with explicit key resolution, deterministic-clock injection, LRU-style eviction, `Retry-After`, and opt-in response quota fields. It intentionally has no implicit client-IP/`X-Forwarded-For` behavior. See `docs/rate-limit.md` for the trust boundary, state bounds, concurrency model, and benchmark status.


Phase 2 adds four independent experimental operational products:

- `WhiteThroatedLogging` — structured request completion events and bounded request IDs.
- `WhiteThroatedMetrics` — bounded-cardinality HTTP counters and latency histograms.
- `WhiteThroatedTracing` — W3C `traceparent` parsing and sampled server spans.
- `WhiteThroatedLifecycle` — readiness, drain rejection, active-request tracking, and ordered cleanup.

```swift
import WhiteThroated
import WhiteThroatedLifecycle
import WhiteThroatedLogging
import WhiteThroatedMetrics
import WhiteThroatedTracing

let lifecycle = LifecycleController()

app.use(
    structuredLogger: StructuredRequestLogger(
        sink: { event in
            print(event)
        }
    )
)

let metrics = HTTPMetrics(
    configuration: HTTPMetricsConfiguration(
        allowedRoutes: ["/health"],
        routeClassifier: { request in
            request.path == "/health"
                ? "/health"
                : nil
        }
    )
)
app.use(metrics: metrics)

app.use(
    tracer: ServerTracer(
        sink: { span in
            print(span)
        }
    )
)

app.use(
    lifecycle: lifecycle,
    readinessPath: "/ready"
)
```

Observability remains opt-in and never logs bodies, credentials, cookies, or arbitrary headers by default. Metrics reject unbounded route labels, tracing samples before building route attributes, and observer middleware preserves prepared responses. See `docs/observability.md` and `docs/lifecycle.md`.


Phase 3 adds experimental identity/state products without adding identity storage to
the core request object:

- `WhiteThroatedAuth`
- `WhiteThroatedSessions`
- `WhiteThroatedRedisSessions`
- `WhiteThroatedCSRF`
- `WhiteThroatedAuthRateLimit`

```swift
import WhiteThroatedAuth

let auth = Authenticator.bearer { token, _ in
    token == expectedToken
        ? AuthPrincipal(
            id: "user-42",
            roles: ["admin"]
        )
        : nil
}

app.get(
    "/admin",
    authenticatedBy: auth,
    authorization: .role("admin")
) { _, principal in
    .text(principal.id)
}
```

Bearer failures include `WWW-Authenticate: Bearer`; API-key failures do not
advertise Bearer. Nested authenticated-group policies are combined with AND,
so child groups cannot weaken parent authorization.

Sessions are loaded explicitly only on routes that need them. The default session
cookie policy is `HttpOnly`, `Secure`, and `SameSite=Lax`; signed cookie
verification supports key rotation. Identity backed by event-loop I/O uses
`EventLoopAuthenticator` with the same authorization route helpers. A bounded
memory store is included for development/tests, while Redis is isolated in a
separate adapter product. See `docs/identity-state.md`.

Phase 4 adds experimental data products that stay outside the core request path:

- `WhiteThroatedServices` — setup-time typed service registry and ordered async
  shutdown.
- `WhiteThroatedDatabase` — async query, row, transaction, and connection-pool
  contract.
- `WhiteThroatedPostgres` — PostgreSQL adapter implemented directly on the
  system `libpq` library, with no third-party driver package.
- `WhiteThroatedMigrations` — checksummed SQL migrations and the
  `whitethroated-migrate` executable.
- `WhiteThroatedORM` — explicit row models and CRUD repositories.

```swift
import WhiteThroatedDatabase
import WhiteThroatedPostgres
import WhiteThroatedServices

// databaseURL comes from the environment or a secret manager.
let database = try await PostgresDatabase.connect(
    configuration: PostgresConfiguration(
        connectionString: databaseURL,
        poolSize: 4
    )
)

let databaseKey = ServiceKey<any Database>("database")
let services = ServiceRegistry()
try services.register(database, for: databaseKey)
try services.onShutdown {
    try await database.shutdown()
}
let container = try services.start()
let db = try container.require(databaseKey)

app.get("/users/:id") { request async throws in
    guard let id = Int64(request.parameter("id") ?? "") else {
        return .text("Invalid id", status: .badRequest)
    }

    let result = try await db.execute(
        DatabaseQuery(
            """
            SELECT "name" FROM "users" WHERE "id" = $1
            """,
            bindings: [.int(id)]
        )
    )

    guard let name = try result.rows.first?
        .decode("name", as: String.self)
    else {
        return .text("Not found", status: .notFound)
    }

    return .text(name)
}
```

`PostgresDatabase` confines blocking libpq calls to per-connection serial queues,
so SwiftNIO event loops never block. It supports cancellation, explicit
connection leases, automatic transaction rollback, and idempotent pool shutdown.
Migration locking holds its advisory lock on a dedicated connection outside the
pool, so concurrent migration runners do not consume pool capacity.

```text
DATABASE_URL='postgresql://user:password@host/db?sslmode=verify-full' \
  .build/release/whitethroated-migrate --status
```

Migration files are applied in lexicographic order, each in its own transaction,
with SHA-256 checksums and an advisory lock. The minimum ORM is deliberately
explicit: `DatabaseModel` declares columns and row decoding, while
`DatabaseRepository` precomputes quoted SQL and receives its connection
explicitly. There is no active-record magic, hidden global connection, or
implicit relationship query. See `docs/data-services.md` for the contract,
install requirements, type mapping, security boundaries, and current limits.

Phase 5 adds production HTTP capabilities as opt-in products. The first is
`WhiteThroatedCompression`:

```swift
import WhiteThroated
import WhiteThroatedCompression

let app = Application()

app.use(compression: Compression(
    configuration: Compression.Configuration(
        minimumBytes: 1024,
        contentTypes: .default
    )
))

app.get("/report") { _ in
    .json(report)
}
```

Compression is explicit: nothing is compressed until the application installs
`app.use(compression:)`, calls `Compression.encode(_:for:)`, prepares a
`Compression.precompressed(_:)` handler, or streams through
`Compression.stream(for:...)`. Buffered `text`, JSON, XML, and SVG
responses at or above `minimumBytes` are negotiated from `Accept-Encoding`
(with quality values), fall back to identity, and carry
`Vary: Accept-Encoding` whenever the response is statically compressible.
Already encoded, file-region, partial-content, and strong-ETag responses are
left untouched, and streaming responses pass through the middleware
untouched; compressed streaming is an explicit per-response API that
preserves writer futures and flushes decodable chunk boundaries. The module
links the system zlib library through a SwiftPM system-library target and adds
no third-party package dependency. See `docs/compression.md` for the
negotiation, validator, and eligibility rules.

Direct TLS is also available through the separate `WhiteThroatedTLS` product:

```swift
import WhiteThroated
import WhiteThroatedTLS

let tls = try DirectTLS(
    certificateChainPEMFile: "/run/secrets/tls.crt",
    privateKeyPEMFile: "/run/secrets/tls.key"
)

app.use(directTLS: tls)
```

The TLS context is built during setup, defaults to TLS 1.2 or newer, disables
renegotiation, and installs its handler before the HTTP pipeline. Core-only
applications do not link SwiftNIO SSL. Reverse-proxy TLS termination remains a
fully supported alternative. See `docs/tls.md` for certificate rotation,
security boundaries, and deployment notes.

Phase 6 adds optional WebSocket and OpenAPI products:

```swift
import WhiteThroatedWebSocket

var sockets = WebSocketRouter()

try sockets.on(
    "/chat",
    handlers: WebSocketHandlers(
        onText: { connection, text in
            _ = connection.sendText(text)
        }
    )
)

app.use(webSockets: sockets)
```

WebSocket registration deliberately selects SwiftNIO's stock HTTP/1 upgrade
pipeline. Frame and message sizes are bounded, fragmented messages are
reassembled with a configured cap, ping/pong and close lifecycle are handled,
and authentication can be composed through the handshake acceptance closure.
See `docs/websocket.md`.

```swift
import WhiteThroatedOpenAPI
import WhiteThroatedValidation

let input = ValidationSchema(
    fields: [
        .path("id", rules: [.nonEmpty]),
    ]
)

var openAPI = OpenAPIRegistry(
    info: OpenAPIInfo(
        title: "Example API",
        version: "1.0.0"
    )
)

try openAPI.register(
    .get,
    "/users/:id",
    operation: OpenAPIOperation(
        operationID: "getUser",
        validation: input
    )
)

try OpenAPIService(
    registry: openAPI
).mount(on: app)
```

OpenAPI metadata is setup-only and opt-in. The registry consumes the same
`ValidationSchema` values used at runtime, rejects operation/route collisions,
and prepares JSON/YAML/UI responses once during setup. See `docs/openapi.md`.

## HTTP/1 transport

The default transport uses WhiteThroated's Tier 1 HTTP/1 parser and response
writer on SwiftNIO event loops and sockets. Applications that register any
request-body streaming route automatically use SwiftNIO's HTTP/1 pipeline for
all connections, preserving upload backpressure and middleware behavior.
Response streaming, SSE, and file-region responses work on either transport.

To select the stock SwiftNIO HTTP/1 pipeline explicitly:

```swift
let app = Application(configuration: ServerConfiguration(
    useTier1HTTP1Experimental: false
))
```

The configuration property's historical name remains supported; its default
is now `true`. Transport selection occurs when a connection is initialized.

## Catch-all routes

A terminal catch-all captures the remaining path without changing static or single-segment parameter precedence.

```swift
app.get("/files/*path") { request in
    .text(request.parameter("path") ?? "")
}
```

`/files/images/2026/avatar.png` produces `images/2026/avatar.png`.

Catch-all parameters must be the final route segment.

## Route groups

Route prefixes are composed during application setup, so groups add no extra request-time routing layer.

```swift
let api = app.group("/api")
let v1 = api.group("/v1")

v1.get("/health", response: .text("ok"))

v1.get("/users/:id") { request in
    .json(#"{"id":"\#(request.parameter("id") ?? "")"}"#)
}
```

## JSON

WhiteThroated supports lazy JSON request decoding and both dynamic and prepared Codable JSON responses.

```swift
struct User: Codable {
    let id: Int
    let name: String
}

app.post("/users") { request in
    guard let user = try? request.decodeJSON(User.self) else {
        return .text("Invalid JSON", status: .badRequest)
    }

    return (try? Response.json(user))
        ?? .internalServerError()
}
```

For immutable Codable payloads, encode once during setup:

```swift
let payload = try PreparedResponse.json(
    User(id: 1, name: "WhiteThroated")
)

app.get("/user", response: payload)
```

## Async/await routes

Swift concurrency is available as an opt-in route type:

```swift
app.get("/profile") { request async throws in
    let profile = try await loadProfile(
        id: request.parameter("id") ?? ""
    )

    return try Response.json(profile)
}
```

Async/await routes use SwiftNIO's `EventLoopPromise.completeWithTask` bridge. A `Task` is created only for a route registered with an async handler. Prepared, synchronous, and NIO-future handlers do not pay this cost.

For event-loop-native I/O where maximum throughput matters, the NIO future handler remains available:

```swift
app.get("/nio") { request, context in
    context.eventLoop.makeSucceededFuture(
        .text("ok")
    )
}
```

## URL-encoded forms

Aggregated request bodies can be read as `application/x-www-form-urlencoded` data without Foundation URL parsing:

```swift
app.post("/login") { request in
    let email = request.form("email") ?? ""
    let remember = request.form("remember") ?? "false"

    return .text("\(email):\(remember)")
}
```

`request.form(name)` scans lazily and stops at the requested field. `request.formParameters` materializes the full dictionary only when needed. Percent escapes and `+` spaces follow standard URL-encoded form semantics.

## Streaming request bodies

Large request bodies can opt into chunk streaming instead of whole-body aggregation:

```swift
final class UploadState: @unchecked Sendable {
    var bytes = 0
}

app.postStream(
    "/upload/:id",
    maxBodyBytes: 100 * 1024 * 1024
) { request, _ in
    let state = UploadState()

    return BodyStreamConsumer(
        onChunk: { chunk in
            state.bytes += chunk.readableBytes
        },
        onEnd: {
            .text(
                "received \(state.bytes) bytes"
            )
        }
    )
}
```

`StreamRequest` exposes method, URI, headers, route parameters, queries, and cookies, but intentionally does not expose an aggregated body.

The synchronous `onChunk` overload returns `Void` and does not allocate an `EventLoopFuture` per chunk. Use it for CPU-only processing, counters, incremental parsers, or sinks that complete synchronously.

For synchronous processing that can fail, use `onChunkThrowing:`. Errors enter WhiteThroated's normal streaming error path without allocating a future on successful chunks:

```swift
BodyStreamConsumer(
    onChunkThrowing: { chunk in
        try parser.consume(chunk)
    },
    onEnd: {
        .noContent()
    }
)
```

For asynchronous sinks, return an `EventLoopFuture<Void>` from `onChunk`:

```swift
onChunk: { chunk in
    fileWriter.write(chunk)
}
```

When a chunk future is returned, WhiteThroated pauses channel auto-read and resumes only after the future completes. Futures from another event loop are hopped back to the request event loop before channel state is touched.

Streaming routes support the normal middleware chain. If middleware short-circuits the request, WhiteThroated drains/discards the incoming body without invoking the stream consumer.

Available registration APIs include:

```swift
app.postStream(...)
app.putStream(...)
app.patchStream(...)
app.deleteStream(...)
app.onStream(.post, ...)
```

Route groups expose the same streaming APIs.

Ordinary routes keep the existing aggregation behavior and do not pay a streaming router lookup unless the same HTTP method has at least one streaming route.

WhiteThroated also handles `Expect: 100-continue` for large uploads. Accepted HTTP/1.1 requests receive an informational `100 Continue` immediately. If a declared `Content-Length` already exceeds the configured limit, WhiteThroated returns `413 Payload Too Large` and closes the connection without waiting for a body the client has not sent. Unsupported expectations receive `417 Expectation Failed`.


### Streaming multipart/form-data

Multipart uploads reuse the request-streaming path and do not require whole-body aggregation:

```swift
final class UploadState: @unchecked Sendable {
    var activePart: MultipartPart?
    var fileBytes = 0
}

app.onError { error, _ in
    if error is MultipartFormDataError {
        return .text(
            "Invalid multipart body",
            status: .badRequest
        )
    }

    return .internalServerError()
}

app.postStream(
    "/upload",
    maxBodyBytes: 100 * 1024 * 1024
) { request, _ in
    let state = UploadState()

    do {
        return try BodyStreamConsumer.multipart(
            request: request,
            onEvent: { event in
                switch event {
                case .partBegin(let part):
                    state.activePart = part

                case .partBody(let chunk):
                    if state.activePart?.isFile == true {
                        state.fileBytes +=
                            chunk.readableBytes
                    }

                case .partEnd:
                    state.activePart = nil
                }
            },
            onEnd: {
                .text(
                    "received \(state.fileBytes) file bytes"
                )
            }
        )
    } catch {
        return BodyStreamConsumer(
            onChunk: { _ in },
            onEnd: {
                .text(
                    "Invalid multipart content type",
                    status: .badRequest
                )
            }
        )
    }
}
```

The helper uses the zero-future throwing synchronous body-stream path internally:

- each incoming chunk is parsed incrementally.
- part bodies are emitted as `ByteBuffer` slices instead of one complete file allocation.
- fragmented boundaries are retained only as a small parser tail.
- `parser.finish()` runs through a throwing synchronous end handler, so malformed closing boundaries enter the normal application error pipeline without creating an end-of-body future.

For lower-level control, `request.multipartParser()` exposes the incremental parser directly.


## Prepared responses

For immutable responses, WhiteThroated can prebuild the body, content length, and HTTP/1.1 response head during application setup.

```swift
app.get(
    "/health",
    response: .text("ok")
)
```

A prepared route is stored directly in the routing trie. On the normal HTTP/1.1 keep-alive path it avoids:

- Route-handler closure invocation.
- Per-request text-to-`ByteBuffer` conversion.
- Per-request content-length formatting.
- Per-request `HTTPResponseHead` construction.

Prepared headers are also built during setup:

```swift
let health = PreparedResponse
    .text("ok")
    .header("cache-control", "no-store")

app.get("/health", response: health)
```

Prepared cookies and redirects keep the same cached-head path:

```swift
let redirect = PreparedResponse.redirect("/login")

let sessionResponse = PreparedResponse
    .text("ready")
    .cookie(
        "session",
        value: "opaque-token",
        options: CookieOptions(
            path: "/",
            httpOnly: true,
            secure: true,
            sameSite: .lax
        )
    )
```

Use prepared responses only for payloads and headers that are truly immutable.

## File-region responses

WhiteThroated can send an existing SwiftNIO `FileRegion` without first copying the file into a `ByteBuffer`:

For browser downloads, add a safe `Content-Disposition` header without hand-building header syntax:

```swift
app.get("/download") { _ in
    Response
        .fileRegion(
            region,
            contentType: "application/zip"
        )
        .attachment("archive.zip")
}
```

Unicode filenames emit both a sanitized quoted fallback and RFC 5987 `filename*`. The helper never performs file I/O; callers still own file opening/stat work and the lifetime of the `FileRegion`.

The zero-copy response itself is unchanged:

```swift
app.get("/download") { _ in
    .fileRegion(
        region,
        contentType: "application/octet-stream"
    )
}
```

The response writer emits `IOData.fileRegion` directly and derives `Content-Length` from the readable region. `HEAD` responses preserve the length while suppressing the file body.

WhiteThroated intentionally does not open filesystem paths synchronously inside this helper. Open files through an appropriate non-blocking/file-service layer, then create the region. The caller owns the underlying file handle and must keep it open until the response write completes.

### ETag conditional responses

ETag matching is opt-in. For immutable content, the fastest path is a conditional prepared route:

```swift
let version = EntityTag("article-v42")
let article = PreparedResponse.html(
    renderArticle()
)

app.get(
    "/article",
    response: article,
    etag: version
)
```

WhiteThroated prebuilds both the tagged 200 response and its bodyless 304 variant during route registration. Bodyless framing normalization is also completed at setup time, so the normal HTTP/1.1 keep-alive writer can reuse the cached response head directly. On a request, the exact route checks `If-None-Match` directly from the request headers and selects cached response storage without constructing `Request` or invoking a handler.

For dynamic content, use the lower-level matcher:

```swift
app.get("/profile") { request in
    let version = EntityTag("profile-v7")

    if request.matchesIfNoneMatch(version) {
        return .notModified(
            etag: version
        )
    }

    return Response
        .json(#"{"fresh":true}"#)
        .etag(version)
}
```

Weak tags are supported with `EntityTag.weak(...)`. `If-None-Match` uses weak comparison semantics, supports `*`, and scans comma-separated entity-tag lists without splitting quoted opaque tags into intermediate strings.

Prepared immutable responses can cache the ETag header during setup:

```swift
let cached = PreparedResponse
    .json(#"{"status":"ok"}"#)
    .etag(EntityTag("status-v1"))
```

### Byte-range downloads

Single HTTP byte ranges are parsed lazily from the `Range` header and can be served as a sliced `FileRegion` without copying file bytes:

```swift
app.get("/video") { request in
    let totalLength = region.readableBytes

    switch request.byteRange(
        totalLength: totalLength
    ) {
    case .none:
        return Response
            .fileRegion(
                region,
                contentType: "video/mp4"
            )
            .acceptingByteRanges()

    case .satisfiable(let range):
        return .partialFileRegion(
            region,
            range: range,
            contentType: "video/mp4"
        )

    case .unsatisfiable:
        return .rangeNotSatisfiable(
            totalLength: totalLength
        )

    case .malformed,
         .unsupportedMultiple,
         .unsupportedUnit:
        return Response
            .fileRegion(
                region,
                contentType: "video/mp4"
            )
            .acceptingByteRanges()
    }
}
```

Supported single-range forms are `bytes=0-99`, `bytes=100-`, and suffix ranges such as `bytes=-500`. Multiple ranges are reported explicitly as unsupported rather than silently constructing a multipart/byteranges response.

### SSE writer

`Response.sse` and `writer.writeSSE(...)` provide server-sent events without first building a normalized intermediate response string:

```swift
app.get("/events") { _ in
    Response.sse { writer in
        writer.writeSSE(
            ServerSentEvent(
                data: "ready",
                event: "status",
                id: "1"
            )
        )
    }
}
```

SSE events are serialized directly into a channel-allocator `ByteBuffer`. CRLF and lone CR in event data are normalized to SSE data lines in one UTF-8 pass.

## Error handling

Register one global application error handler for failed NIO futures, thrown async/await routes, and streaming consumer failures:

```swift
app.onError { error, _ in
    Response.text(
        "Request failed",
        status: .internalServerError
    )
}
```

NIO-future handlers are also supported:

```swift
let handler: ErrorHandler = { error, context in
    context.eventLoop.makeSucceededFuture(
        .json(
            #"{"error":"internal"}"#,
            status: .internalServerError
        )
    )
}

app.onError(handler)
```

And Swift concurrency is opt-in:

```swift
app.onError { error, context async throws in
    try await report(error)

    return .text(
        "Request failed",
        status: .internalServerError
    )
}
```

Error handling is not inserted into the successful request pipeline. Prepared, synchronous, and successful asynchronous routes do not perform an error-handler lookup. If a custom future/async error handler itself fails, WhiteThroated writes the built-in `500 Internal Server Error` directly and does not recursively invoke the custom handler.

Only one global handler is active; the most recent `onError` registration replaces the previous one. Error handlers receive the error and event-loop `Context`, not mutable request state.

## Streaming responses

For generated output that should not be buffered into one large body, return a response stream:

```swift
app.get("/events") { _ in
    Response.stream(
        contentType: "text/event-stream"
    ) { writer in
        writer.writeStringAndFlush(
            "data: ready\n\n"
        )
    }
}
```

The producer returns an `EventLoopFuture<Void>`. WhiteThroated writes the final HTTP `end` part automatically after that future succeeds.

Multiple chunks can be chained without flushing each chunk:

```swift
app.get("/stream") { _ in
    Response.stream(
        contentType: "text/plain"
    ) { writer in
        writer.writeString("hello").flatMap {
            writer.writeString(" world")
        }
    }
}
```

`ResponseStreamWriter` exposes:

- `write(_:)` and `writeString(_:)` for buffered in-memory writes.
- `writeFileRegion(_:)` for direct file-region body parts.
- `writeAndFlush(_:)`, `writeStringAndFlush(_:)`, and `writeFileRegionAndFlush(_:)` for latency-sensitive output.
- `flush()` to flush previously queued chunks.
- `eventLoop` for scheduling NIO-native asynchronous work.
- `closeFuture` to observe client disconnects.

Stream writes must be serialized on the writer's event loop. If a stream producer fails after response headers have started, WhiteThroated closes the connection rather than attempting to send a second HTTP response. Use the optional `onError` closure on `Response.stream` or `Response.sse` to clean up producer-owned resources before the connection is closed.

For HTTP/1.1 responses without a declared `Content-Length`, the selected transport owns chunked transfer framing. For HTTP/1.0, WhiteThroated closes the connection after an unknown-length stream unless the response explicitly provides a content length.

HEAD requests suppress the stream producer entirely.

### Server-Sent Events

SSE is a small convenience layer over response streaming:

```swift
app.get("/events") { _ in
    Response.sse { writer in
        writer.writeSSE(
            ServerSentEvent(
                data: "build complete",
                event: "status",
                id: "42"
            )
        )
    }
}
```

`writeSSE` flushes each event by default for low delivery latency. Pass `flush: false` when several events should be batched before an explicit `writer.flush()`.

## Connection metadata

Handlers that already receive `Context` can read the raw peer socket address:

```swift
app.get("/peer") { _, context in
    let peer =
        context.remoteAddress?.description
        ?? "unknown"

    return context.eventLoop
        .makeSucceededFuture(
            .text(peer)
        )
}
```

`remoteAddress` is the transport peer reported by SwiftNIO. WhiteThroated does not automatically trust or parse `X-Forwarded-For` or similar proxy headers. Applications behind a trusted reverse proxy should apply their own explicit proxy-trust policy.

Prepared and ordinary synchronous routes do not construct `Context`, so this metadata does not add address lookup work to those fast paths.


When running behind a trusted reverse proxy, forwarded client IP resolution is explicit:

```swift
let trustedProxy = ProxyTrustPolicy { address in
    address.ipAddress == "10.0.0.10"
}

app.get("/client-ip") { request, context in
    let clientIP = context.clientIPAddress(
        for: request,
        trusting: trustedProxy
    ) ?? "unknown"

    return context.eventLoop
        .makeSucceededFuture(
            .text(clientIP)
        )
}
```

The resolver walks `X-Forwarded-For` from right to left. It only advances while the current hop is trusted. An untrusted immediate peer causes the header to be ignored completely, and malformed hops stop resolution rather than allowing the resolver to jump across a trust boundary.

## Middleware

The regular middleware API supports asynchronous NIO work:

```swift
app.use { request, _, next in
    next(request).map { response in
        var response = response
        response.headers.add(
            name: "x-powered-by",
            value: "WhiteThroated"
        )
        return response
    }
}
```

For middleware that does not require asynchronous I/O, `useFast` preserves WhiteThroated's synchronous and prepared responder paths:

```swift
app.useFast { request, _, next in
    next(request)
}
```

A pass-through `useFast` middleware does not force an `EventLoopFuture` allocation.

## Current core

- SwiftNIO-based HTTP/1.1 transport.
- Express-style route registration and zero-overhead route groups.
- Direct method roots for common HTTP methods.
- Exact full-path static route table before trie fallback.
- UTF-8 trie routing.
- Route precedence: static segment, dynamic `:param`, then terminal `*catchAll`.
- Routing directly over the URI UTF-8 view with a contiguous-byte fast path.
- Parameter-only trie nodes skip unused static hashing.
- Terminal static/parameter routes avoid an extra recursive matcher call.
- Lazy route parameter decoding from byte ranges.
- Contiguous-byte fast paths for route parameter and targeted query decoding.
- Inline parameter name/range storage for the first two dynamic parameters.
- Lazy query scanning and percent decoding.
- Lazy conversion from SwiftNIO HTTP methods to WhiteThroated's public method enum.
- Synchronous responder fast path.
- Prepared immutable response fast path.
- Immutable shared prepared-response storage carried directly through the internal pipeline.
- Precomputed HTTP/1.1 heads and body buffers for prepared responses.
- NIO future handlers for asynchronous I/O.
- Global sync, NIO-future, or async/await error handling on failure paths only.
- Compiled asynchronous middleware pipeline.
- Synchronous `useFast` middleware pipeline.
- Opt-in async/await route handlers through SwiftNIO's Task bridge.
- Direct `ByteBuffer` response support.
- Direct `FileRegion` response support through NIO `IOData.fileRegion`.
- Opt-in streaming responses with framework-owned HTTP termination.
- Direct SwiftNIO `FileRegion` response support without ByteBuffer copying.
- Bodyless-request empty-buffer reuse.
- First request-body chunk reuse instead of unconditional copying.
- Opt-in request-body streaming with per-route limits and async backpressure.
- Streaming multipart/form-data parsing with bounded part/header limits.
- Streaming middleware compatibility without whole-body aggregation.
- Configurable request-body limits.
- Opt-in streaming request bodies with per-route limits and backpressure.
- Early rejection of declared oversized streaming bodies before consumer creation.
- HTTP keep-alive and pipelining assistance.
- `Expect: 100-continue` handling with early 413/417 rejection.
- Express-style `HEAD` fallback to matching `GET` routes.
- Correct `HEAD` body suppression while preserving `Content-Length`.
- Configurable event-loop thread count and listen backlog.
- Release benchmark server.
- Raw SwiftNIO control benchmark server.
- Swift-only benchmark implementation sources.
- Raw SwiftNIO control benchmark server written in Swift.
- Opt-in Swift benchmark routes for streaming, multipart, router stress, and conditional responses.
- External cross-framework controls kept outside the WhiteThroated repository.

## Request lifecycle

```text
Socket
  |
  v
SwiftNIO EventLoop
  |
  v
HTTP/1 Decoder
  |
  v
Direct HTTP-method root
  |
  +-- exact static route ----------> endpoint
  |
  v
UTF-8 route trie fallback
  |
  +-- prepared/no middleware -----> cached storage
  |
  v
Request wrapping when required
  |
  v
Compiled middleware / handler
  |
  +-- prepared response -----------+
  |                                |
  +-- synchronous handler -----+   |
  |                            |   |
  +-- future handler ------+   |   |
                          |   |   |
                          v   v   v
                      response writer
                          |
                          v
                        Socket
```

The transport half of that lifecycle lives in the internal
`WhiteThroatedRuntime` module:

```text
Developer API
     |
     v
WhiteThroated ── Application, Router, middleware, Request/Response
     |
     v
WhiteThroatedRuntime ── bootstrap, HTTP/1.1 pipeline, dispatch,
     |                  response writer, keep-alive, backpressure
     +── WhiteThroatedHTTP1 ── byte parser and response serializer
     v
SwiftNIO
     |
     v
OS networking
```

`WhiteThroatedRuntime` is an implementation layer in this same
repository, not a separate framework or package. Users import only
`WhiteThroated`; the runtime owns low-level HTTP execution so
framework code stays focused on developer-facing behavior. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the module boundary and
event-loop ownership rules.

## Performance rules

WhiteThroated follows several runtime rules:

- Do not create a Swift concurrency `Task` on the default request path.
- Do not split request paths into arrays of Swift `String` values.
- Do not eagerly decode route parameters.
- Do not eagerly parse query parameters.
- Keep synchronous work synchronous.
- Keep reusable response bytes reusable.
- Prefer setup-time work over per-request work.
- Keep the event loop non-blocking.
- Treat allocation count, ARC traffic, CPU, memory, and tail latency as first-class metrics.
- Never publish a speed claim without a reproducible benchmark configuration.

## Why SwiftNIO

SwiftNIO provides the event-loop and non-blocking I/O foundation while WhiteThroated keeps control over routing, middleware dispatch, request representation, response serialization, allocation behavior, and public API design.

The goal is not to build a large abstraction stack on top of NIO. The goal is to keep the distance between socket and handler small enough to profile and optimize.

## Run

```bash
swift run -c release whitethroated-example
```

The example listens on `127.0.0.1:3000`.

## Test

```bash
swift test -c release
```

## Benchmark

WhiteThroated keeps benchmark implementation code in Swift.

Run the in-process dispatch benchmark:

```bash
WHITETHROATED_CORE_BENCHMARK=1 \
WHITETHROATED_CORE_ITERATIONS=5000000 \
swift test -c release \
  --filter CoreBenchmarkTests/testCoreDispatchBenchmark
```

Run the router-only diagnostic:

```bash
WHITETHROATED_ROUTER_CORE_BENCHMARK=1 \
WHITETHROATED_ROUTER_CORE_ITERATIONS=10000000 \
swift test -c release \
  --filter CoreBenchmarkTests/testRouterLookupBenchmark
```

Run the transport writer diagnostic:

```bash
WHITETHROATED_TRANSPORT_BENCHMARK=1 \
WHITETHROATED_TRANSPORT_ITERATIONS=500000 \
swift test -c release \
  --filter CoreBenchmarkTests/testTransportWriterBenchmark
```

Start the WhiteThroated release benchmark server:

```bash
WHITETHROATED_THREADS=4 \
swift run -c release whitethroated-benchmark-server
```

Start the raw SwiftNIO control separately with the same worker count:

```bash
WHITETHROATED_THREADS=4 \
swift run -c release raw-nio-benchmark-server
```

Start the runtime-level server to separate runtime overhead from framework overhead:

```bash
WHITETHROATED_THREADS=4 \
swift run -c release whitethroated-runtime-benchmark-server
```

Use the same external load generator and identical settings for every server. Actix and other non-Swift controls intentionally live outside this repository so WhiteThroated remains a Swift-only codebase.

See [BENCHMARKS.md](BENCHMARKS.md) for the benchmark protocol and [ARCHITECTURE.md](ARCHITECTURE.md) for runtime invariants.

## Next performance targets

1. Run the repeated WhiteThroated-to-raw-NIO suite on pinned hardware and record median/p99 deltas.
2. Run the core dispatch and writer benchmarks before changing NIO response-part boxing.
3. Measure `/plaintext`, `/future`, and `/concurrent` with identical network load to separate synchronous dispatch, NIO-future handling, and Swift concurrency bridge overhead.
4. Profile ARC retain/release traffic for prepared, synchronous, dynamic-parameter, future-based, async/await, and streaming routes.
5. Quantify route depth/fan-out and middleware scaling with the committed matrices.
6. Measure aggregated versus streaming uploads with both throughput and peak-RSS runners.
7. Measure known-length, chunked, and flush-heavy response streams independently.
8. Compare the pinned Actix Web control only after WhiteThroated's raw-NIO framework overhead is measured and explained.
