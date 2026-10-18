# WhiteThroatedHTTP1 Agent Guide

Scoped rules for the experimental server-only HTTP/1 codec. Precedence:
user request > this file > root `AGENTS.md` > `ARCHITECTURE.md`.

## Module purpose

`WhiteThroatedHTTP1` is an experiment (Phase 2): a server-only HTTP/1
parser plus direct response writer that replaces `NIOHTTP1` on the hot
path while staying on `NIOCore`/`NIOPosix` as the I/O substrate.

## Hard constraints

- This module must import only `NIOCore` (plus Swift stdlib/Foundation
  where unavoidable). Never import `NIOHTTP1`, `NIOPosix`,
  `WhiteThroated`, or `WhiteThroatedRuntime`.
- Server-only: no client request serialization, no client response
  parsing, no WebSocket, no TLS, no HTTP/2+.
- No framework concepts: no routing, middleware, Request/Response, or
  dispatcher knowledge. The module speaks bytes, heads, and framing.
- Validation equivalence with the pinned SwiftNIO behavior is a proof
  obligation: every divergence must be a documented, tested, strictly
  safer direction (reject, never silently accept).
- The strict/safe direction on ambiguity is always reject (400 + close),
  mirroring `HTTPServerProtocolErrorHandler`. Never invent permissive
  parsing that could create request-smuggling ambiguity.

## Correctness bar

- Every parser accept/reject rule needs a unit test, including adversarial
  input: smuggling (CL+TE), duplicate/contradictory Content-Length,
  bad chunk framing, chunk extensions, trailers (validated then
  discarded, framing-equivalent with stock), bare CR, LF-only lines,
  obs-fold, oversized heads, split feeds,
  pipelined requests, 100-continue, HTTP/1.0 vs 1.1, HEAD semantics.
- Differential-test header validation against NIO's outbound validator
  behavior through `EmbeddedChannel` (NIO's rules are internal, so test
  through the public handler, never by re-implementing from memory alone).
- Fast paths need hit/miss/boundary/invalidation coverage like any other
  runtime fast path. See root `AGENTS.md` testing policy.

## Performance bar

- No per-request heap allocation in the parser for minimal requests beyond
  retaining the head-bytes buffer once; no String materialization until
  a consumer asks for decoded text.
- Writer must serialize a prepared response from immutable prebuilt bytes
  with no per-request validation, copy, or framing scan (validated once
  at setup; bytes are immutable so the verdict cannot change).
- Measure with the in-process codec benchmark before claiming anything,
  then the network A/B. Same rules as `benchmark-validation`.
