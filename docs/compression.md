# WhiteThroatedCompression

Status: **experimental**

`WhiteThroatedCompression` is opt-in buffered gzip compression. Importing the
product does not install middleware, register routes, or change WhiteThroated
core/runtime behavior.

## Basic use

Install the fast middleware for application-wide negotiation:

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
```

Or compress inside a single handler without installing middleware:

```swift
let compression = Compression()

app.get("/report") { request in
    compression.encode(.json(report), for: request)
}
```

Or prepare encoded representations once at setup:

```swift
let handler = try Compression().precompressed(
    .text(manual)
)

app.get("/manual", use: handler)
```

Streaming responses declare compression explicitly because their
bodies are written after the response head:

```swift
let compression = Compression()

app.get("/events") { request in
    compression.stream(
        for: request,
        contentType: "text/plain"
    ) { writer in
        writer.writeStringAndFlush("first\n")
        return writer.writeStringAndFlush("second\n")
    }
}
```

Writes are deflated on the connection event loop; every returned future
is the underlying writer future, so backpressure is preserved. Each
`writeAndFlush` ends on a `Z_SYNC_FLUSH` boundary so incremental
decoders can read chunks before the stream ends, and the gzip trailer is
appended when the producer's future completes. `Compression.StreamWriter`
mirrors the compressible subset of `ResponseStreamWriter`; file-region
writes are intentionally unavailable.

## Configuration

```swift
Compression.Configuration(
    algorithms: [.gzip],
    minimumBytes: 1024,
    compressionLevel: 6,
    contentTypes: .default
)
```

- `algorithms` is ordered; gzip is the only implemented coding.
- `minimumBytes` skips small payloads. Zero-length bodies are never
  compressed regardless of this setting.
- `compressionLevel` maps to the zlib level (0–9).
- `contentTypes` decides which media types may be compressed:

  - `.default` covers `text/*`, JSON variants, JavaScript, XML variants,
    `image/svg+xml`, and `application/wasm`;
  - `.allowAll` compresses every response that has a content type;
  - `.only(["application/x-custom"])` compresses exactly the listed media
    types and supports `type/*` wildcards.

  Matching is ASCII case-insensitive and ignores media-type parameters.
  Responses without a `content-type` header are never compressed.

## Negotiation

Negotiation follows RFC 9110 `Accept-Encoding` semantics and reads only the
request's `accept-encoding` headers:

- a missing header accepts identity only;
- a present header accepts the codings it lists plus `*`, and ignores unknown
  tokens;
- identity is acceptable unless `identity;q=0` denies it, or `*;q=0` denies it
  and no explicit `identity` entry grants it back;
- a malformed quality value invalidates that coding entry only;
- repeated codings use their highest quality;
- ties prefer the configured algorithm order;
- an algorithm is chosen only when its quality is at least the identity
  quality.

`encode(_:for:)` and the middleware are opportunistic: when the client cannot
receive a configured coding, the identity representation is served and the
status is never rewritten into an error. `precompressed(_:)` is strict: a
request that denies identity and accepts no configured algorithm receives
`406 Not Acceptable`.

## Eligibility

A buffered response is statically eligible only when all of the following
hold:

- the status may carry a body (1xx, 204, and 304 are excluded);
- the body is buffered (`.text`, `.bytes`, or `.buffer`); file regions and
  streams are excluded;
- the body is not empty and reaches `minimumBytes`;
- no `content-encoding`, `transfer-encoding`, or `content-range` header is
  present, and the status is not `206 Partial Content`;
- the content type matches the configured policy.

Ineligible responses are returned byte-for-byte unchanged and receive no
`Vary` header.

## Entity tags

Compressed and identity representations need distinct strong validators.
Therefore:

- a response carrying a strong entity tag, multiple entity tags, or a
  malformed entity tag is never compressed; `encode(_:for:)` and the
  middleware pass it through untouched (without adding `Vary`), and
  `precompressed(_:)` throws `CompressionError.conflictingETag` during setup;
- a response carrying exactly one well-formed weak tag (`W/"..."`) may be
  compressed, and the weak tag is preserved.

## Vary

Every statically eligible response receives `Vary: Accept-Encoding`, whether
the identity or an encoded representation is served. Existing `Vary` values
are preserved, duplicate `Accept-Encoding` tokens are not added twice, and an
existing `Vary: *` is treated as covering.

When gzip is applied, `content-encoding: gzip` and a `content-length` matching
the compressed buffer replace any prior framing headers. Identity responses
keep their original framing.

## Middleware, prepared responses, and streams

The fast middleware only rewrites immediate and future responses. Prepared
responses pass through untouched so prepared routes keep the prepared writer
path; response streams pass through untouched to preserve streaming
backpressure. Use `precompressed(_:)` for prepared-style routes that need an
encoded representation: encoding happens once during setup and the returned
synchronous handler only performs negotiation.

Use `stream(for:contentType:status:onError:produce:)` for compressed
streaming. It is statically eligible when the status may carry a body and the
declared content type matches the configured policy, and it is opportunistic
like `encode(_:for:)`: a request that cannot receive a configured coding gets
the identity stream, and a statically ineligible stream gets no `Vary` header.
A `nil` or disallowed content type therefore streams identity; use
`.allowAll` or `.only([...])` to widen the policy. The module never changes
`content-length` semantics for streams: compressed streams are framed
without a declared length, exactly like identity streams.

`Compression` is immutable and `Sendable`; sharing one instance across routes
and connections is expected.

## Library and portability

The module links the system zlib library through the `CZlib` SwiftPM
system-library target (`link "z"`, `pkg-config: zlib`). It adds no third-party
package dependency. On Debian/Ubuntu install `zlib1g-dev`; on macOS zlib ships
with the platform SDK. Compression is synchronous CPU work on the connection
event loop and performs no blocking I/O, no locking, and no `Task` creation.
Each active compressed stream owns one zlib deflate state until its producer
completes.

## Current boundaries

This slice intentionally includes only gzip negotiation for buffered and
streamed bodies. It does not yet provide:

- brotli, zstd, or raw deflate codings;
- precompressed file/on-disk representation caches;
- a compression dictionary or per-type level policy;
- automatic `Content-MD5`/`Digest` recomputation (no such headers are
  generated by the core).

Applications must not point `precompressed(_:)` at responses whose headers
claim a checksum over the identity bytes.

## Benchmark status

No performance claim is made yet. Before promotion beyond experimental, record
the roadmap's three conditions independently:

1. module disabled (core routes with the product not installed);
2. module installed but no route compresses;
3. middleware active on compressible and incompressible responses.

At minimum record RPS, p50/p90/p99/p99.999/max latency, response/body
throughput, and peak RSS for the active matrix.
