# WhiteThroatedStaticFiles

Status: experimental

`WhiteThroatedStaticFiles` is an opt-in SwiftPM product for serving files from
an explicitly opened directory. Importing the product alone does not register
routes, open files, or change the core/runtime transport.

## Minimal setup

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

Opening the root directory is explicit and asynchronous. Applications own the
`StaticFiles` lifecycle and must call `close()` after the server stops.

## Request behavior

A mount at `/assets` serves only that route prefix. WhiteThroated registers an
exact GET route and a terminal catch-all route during application setup; it
does not install global static-file middleware. HEAD uses WhiteThroated's
normal GET-to-HEAD route fallback.

The experimental implementation currently provides:

- GET and HEAD.
- common web MIME types plus setup-time extension overrides.
- `Accept-Ranges: bytes`.
- one HTTP byte range with 206/416 behavior.
- weak ETags derived from file size and modification time.
- `If-None-Match` / 304.
- optional index-file lookup.
- optional `Cache-Control`.
- known-length file-region streaming on both supported HTTP/1 transports.

Malformed ranges, unsupported range units, and multiple ranges are ignored and
the complete representation is served. A syntactically valid but
unsatisfiable byte range receives 416. `If-Range` validation is not implemented
yet; when that header is present, the module conservatively ignores the Range
request and serves the complete representation instead of risking a stale
partial response.

Directory listing, SPA fallback, precompressed assets, download disposition,
and multiple ranges are not part of this experimental slice yet.

## Filesystem and event-loop behavior

Filesystem metadata and open operations use SwiftNIO's filesystem executor.
They are not executed synchronously on a connection event-loop thread.

The file is opened before its descriptor is detached into a SwiftNIO
`FileRegion`. The response stream keeps that descriptor alive until the
flushed file-region write completes, then closes it. Empty files and HEAD
responses do not emit an empty file region.

The root directory stays open for the lifetime of `StaticFiles`; this is why
the explicit `close()` call is required.

## Path security

The default policy is intentionally restrictive:

- percent decoding occurs exactly once.
- malformed percent escapes are rejected.
- raw or percent-encoded NUL bytes are rejected.
- raw or percent-encoded path separators are rejected.
- empty interior path components, `.`, and `..` are rejected.
- the root directory is opened with symbolic-link following disabled.
- every intermediate directory component is opened relative to the previous
  directory handle with symbolic-link following disabled.
- the final file is opened with symbolic-link following disabled.
- only regular files are served.
- directory listing is never enabled implicitly.

A double-encoded percent sequence is decoded once and remains a literal percent
sequence in the filesystem component. It is never decoded a second time.

The component-by-component no-follow traversal is the containment boundary; it
does not rely on string-prefix checks of a canonicalized absolute path.

## Cache and validators

The default weak ETag is generated from the opened file's size and
last-data-modification timestamp. It is intended as an inexpensive validator,
not as a content hash.

`StaticFileOptions.production` currently adds:

```text
Cache-Control: public, max-age=3600
```

Applications can provide a different cache-control value or leave it unset.

## Performance status

No StaticFiles performance claim is published yet. Before promotion beyond
experimental, the feature-specific benchmark must measure:

1. core application without the module,
2. module linked/configured while the tested route does not use it,
3. active static-file requests against a semantically equivalent control.

The benchmark record must include latency percentiles, throughput, errors,
completed requests, peak RSS, and response throughput in release builds across
multiple alternating rounds.

## Current limitations

This first vertical slice intentionally does not yet include:

- directory listing,
- configurable symlink-following policy,
- SPA fallback,
- precompressed Brotli/gzip selection,
- `If-Modified-Since` / `Last-Modified`,
- full `If-Range` validator semantics,
- multipart byte ranges,
- content-disposition helpers at the mount layer,
- a lifecycle hook that closes the root automatically.

Those capabilities require separate correctness, security, and benchmark
evidence before being added.
