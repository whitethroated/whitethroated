# Skill: protocol contracts

Use this skill whenever changing WebSocket, OpenAPI, direct TLS, compression,
HTTP upgrade behavior, or another capability whose correctness depends on an
external protocol or wire/document contract.

This skill complements, rather than replaces:

- `.agents/skills/http-correctness-security/SKILL.md`;
- `.agents/skills/swiftnio-http-runtime/SKILL.md`;
- `.agents/skills/testing-regression/SKILL.md`;
- `.agents/skills/benchmark-validation/SKILL.md` for performance work.

## Principle

Protocol implementations are state machines and contracts, not collections of
convenience helpers.

An optimization is valid only if externally observable protocol semantics remain
correct across normal, boundary, malformed, cancellation, and shutdown paths.

Do not infer protocol correctness from a happy-path integration test.

## Contract first

Before changing a protocol path, identify:

- the governing RFC/specification or explicit WhiteThroated contract;
- setup-time invariants;
- connection/request/message states;
- legal transitions;
- terminal states;
- size and resource limits;
- error mapping;
- fallback behavior;
- interaction with HTTP framing and connection lifecycle.

Keep the implementation narrower than the specification when the product
intentionally supports only a subset.

Do not advertise unsupported capabilities.

## State-machine discipline

Represent connection/message lifecycle so every state transition has one owner.

Review:

- initialization;
- activation/handshake;
- active data flow;
- partial/fragmented input;
- local failure;
- peer failure;
- local close;
- peer close;
- timeout;
- transport close;
- cleanup.

Terminal callbacks/completions must occur at most once.

Do not allow late asynchronous completion to resurrect a terminal state.

## WebSocket handshake

For WebSocket changes, preserve the HTTP upgrade boundary.

Review:

- fresh-connection assumptions of the configured SwiftNIO upgrader;
- Upgrade and Connection token handling;
- Sec-WebSocket-Version;
- Sec-WebSocket-Key validation;
- subprotocol negotiation;
- route selection;
- authentication/acceptance;
- fallback to normal HTTP routing;
- connection close after unsupported/refused upgrade when required by the
  pipeline state.

Do not synthesize authentication semantics in the WebSocket layer when the
documented contract delegates refusal to ordinary HTTP routing.

If upgrade succeeds, remove/replace HTTP handlers in the correct order before
application frame handling begins.

## WebSocket framing

Preserve RFC 6455 framing requirements.

Validate applicable rules:

- client masking;
- FIN and continuation ordering;
- RSV bits;
- opcode validity;
- control frame FIN requirement;
- control payload limit;
- frame size limit;
- reassembled message size limit;
- UTF-8 validity for text;
- ping/pong payload echo;
- close payload/code validity;
- fragmented message lifecycle.

Do not allow fragment accumulation beyond the configured message limit.

Do not retain unbounded frame/message data after connection termination.

## WebSocket close semantics

Close is a protocol exchange, not just a socket close.

Review:

- server-initiated close;
- peer-initiated close;
- close echo;
- close timeout;
- transport failure;
- protocol-error close;
- onClose exactly-once behavior.

After terminal close begins, prevent application data writes that violate the
documented state.

Do not wait forever for a peer close; keep the transport-close timeout bounded.

## WebSocket execution model

Application WebSocket handlers run according to the module's documented
event-loop model.

Do not:

- block the channel event loop;
- create an implicit Swift Task per message;
- hop event loops without ownership need;
- drop write futures;
- ignore backpressure;
- share mutable connection state across loops without synchronization.

Any future returned by acceptance or write operations must be observed on the
appropriate event loop.

## WebSocket extensions

Do not set RSV bits or accept extension-specific frames unless the extension was
actually negotiated.

Per-message compression or another extension is a separate capability with its
own memory, negotiation, and security contract.

Do not silently enable extensions because a dependency supports them.

## OpenAPI source of truth

OpenAPI metadata must describe behavior the application actually intends to
serve.

Where WhiteThroated shares a validation schema between runtime validation and
OpenAPI generation, preserve that single-source relationship.

Do not:

- document a path parameter that does not exist;
- omit a route placeholder from the OpenAPI contract;
- mark a path parameter optional;
- emit duplicate method/path operations;
- emit duplicate operation IDs;
- represent an unsupported custom validation closure as a standard portable
  JSON Schema constraint.

Use vendor extensions when operational constraints cannot be expressed honestly
in standard schema.

## OpenAPI setup-time validation

OpenAPI registration/generation should remain setup-time work.

Reject invalid metadata early.

Examples:

- operation-ID collision;
- route collision;
- undocumented placeholder;
- validation field for a nonexistent path parameter;
- method unsupported by OpenAPI Path Items;
- invalid schema relationship.

Do not add per-request route introspection merely to generate documentation.

Prepared OpenAPI documents should remain immutable after setup unless a future
dynamic mode is explicitly designed.

## OpenAPI document stability

Generated documents should be deterministic for the same registered contract.

Avoid output that depends on:

- dictionary iteration accidents;
- process-specific addresses;
- timestamps not required by the contract;
- nondeterministic registration races.

Deterministic output improves tests, caching, diffs, and client generation.

When changing generated schema shape, treat it as a public contract change even
if runtime routing did not change.

## TLS setup boundary

Direct TLS configuration is setup-time security state.

Certificate/private-key loading and TLS context construction may perform
blocking file I/O and must not move onto event-loop callbacks.

Review:

- certificate chain loading;
- private key loading;
- minimum TLS version;
- renegotiation policy;
- ALPN;
- client verification if introduced;
- certificate rotation model;
- handler insertion order.

Do not add a trust-all or validation-off default.

## TLS ALPN

Only advertise protocols the serving pipeline can actually handle.

If WhiteThroated is serving HTTP/1.1 only, do not advertise h2 merely because the
TLS library accepts the configuration.

Validate ALPN identifiers before passing them to the TLS stack.

Negotiating an unsupported protocol is a correctness bug, not a graceful
feature fallback.

## TLS secret handling

Treat certificate private keys and related credentials as secrets.

Do not log:

- PEM private key bytes;
- passwords protecting keys;
- secret file contents.

Error messages may identify the configured path when appropriate but must not
include secret material.

If configuration accepts in-memory PEM bytes, preserve caller ownership and
avoid unnecessary copies where practical without extending secret lifetime
accidentally.

## TLS certificate rotation

If the product uses an immutable TLS context created at setup, document that
certificate rotation requires controlled restart/rollout.

Do not hide rotation behind mutable global state unless a separately designed
thread-safe/context-safe mechanism exists.

## Compression negotiation

Compression must follow the declared HTTP content-coding contract.

Review:

- Accept-Encoding parsing;
- q-values;
- wildcard semantics;
- identity semantics;
- repeated codings;
- malformed q-values;
- configured algorithm preference;
- response eligibility.

Do not compress merely because the client mentioned gzip somewhere in a malformed
or lower-priority negotiation.

## Compression response semantics

When an encoded representation is selected, preserve:

- Content-Encoding;
- Content-Length for buffered responses;
- Transfer-Encoding semantics;
- Vary: Accept-Encoding;
- status/body restrictions;
- range/Content-Range interaction;
- entity validator semantics.

Do not compress:

- status codes that cannot carry a body;
- empty bodies if the module contract excludes them;
- 206/range responses when the module cannot preserve representation semantics;
- already encoded responses;
- response shapes explicitly excluded by the contract.

Prepared, buffered, file, and streaming responses may have different supported
paths. Keep those differences explicit.

## Compression validators

A compressed representation is not byte-identical to the identity
representation.

Do not reuse a strong ETag across representations unless it was intentionally
defined for that exact representation.

Preserve the documented weak-validator behavior.

If the module cannot safely reinterpret a validator, skip compression or reject
setup according to the public contract.

## Compression streaming

Streaming compression must preserve incremental delivery and backpressure.

Review:

- compressor initialization;
- each write;
- flush mode;
- terminal flush/trailer;
- producer failure;
- writer failure;
- exactly-once finalization;
- cleanup of compression state.

Do not buffer the full stream merely to reuse buffered-response code.

Do not declare Content-Length for a compressed stream unless the exact encoded
length is known before the head is written.

Each active stream must have bounded, owned compressor state.

## Cross-protocol interactions

Protocol capabilities can interact in non-obvious ways.

Review relevant combinations:

- TLS + HTTP upgrade;
- compression + conditional responses;
- compression + ranges;
- compression + HEAD;
- WebSocket authentication + ordinary HTTP fallback;
- WebSocket + trusted proxy;
- OpenAPI + Validation;
- OpenAPI + route naming/path syntax;
- TLS + forwarded scheme;
- observability + protocol payload privacy.

Do not assume two individually correct modules compose correctly without a
boundary test.

## Limits

External protocols must have explicit resource limits.

Examples:

- WebSocket frame bytes;
- WebSocket reassembled message bytes;
- control frame size;
- compressed stream state;
- request/document schema depth;
- generated OpenAPI document size when future dynamic inputs exist;
- handshake/header limits inherited from HTTP.

Limits should fail predictably and release resources promptly.

Do not add an "unlimited" default for externally controlled input.

## Error mapping

Keep protocol errors distinct from application errors.

Examples:

- malformed WebSocket frame;
- authentication refusal;
- application handler failure;
- TLS handshake failure;
- invalid compression negotiation;
- OpenAPI setup collision.

Map errors according to the layer that owns them.

Do not expose internal exception detail on the wire by default.

Do not convert every protocol failure into HTTP 500.

## Testing strategy

Use protocol-level tests for the state machine and real transport tests for
behavior the embedded harness cannot faithfully model.

For WebSocket, cover applicable cases:

- valid upgrade;
- invalid key/version;
- refused upgrade and HTTP fallback;
- subprotocol negotiation;
- unmasked frame;
- RSV violation;
- fragmented text/binary;
- invalid continuation;
- invalid UTF-8;
- oversized frame/message;
- ping/pong;
- peer close;
- server close;
- close timeout;
- write failure;
- onClose exactly once.

For OpenAPI, cover:

- valid path conversion;
- placeholder/schema mismatch;
- optional path rejection;
- duplicate path/method;
- duplicate operation ID;
- deterministic output;
- custom-validation vendor extension;
- document serving.

For TLS, cover:

- valid setup;
- invalid certificate/key;
- protocol minimum configuration;
- ALPN rejection for unsupported protocols;
- handler ordering;
- handshake where feasible;
- core-only behavior unaffected.

For compression, cover:

- absent Accept-Encoding;
- gzip accepted/denied;
- identity q-values;
- wildcard;
- malformed q-value;
- Vary behavior;
- strong/weak ETag;
- status/body exclusions;
- range exclusions;
- prepared response;
- streaming flush/finalization;
- producer/write failure.

## Benchmarking

Use `.agents/skills/benchmark-validation/SKILL.md` for performance claims.

For optional protocol modules, distinguish:

1. product/capability absent;
2. capability installed but inactive;
3. capability active.

Measure protocol-relevant work, not only HTTP request count.

Examples:

- WebSocket message throughput and message latency;
- compression body throughput and CPU/memory cost;
- TLS handshake and steady-state request cost when relevant;
- OpenAPI setup/generation cost separately from prepared serving cost.

Capture tail latency and errors.

GitHub-hosted CI validates harness execution, not stable performance.

## Documentation

When protocol behavior changes, update the relevant document:

- `docs/websocket.md`;
- `docs/openapi.md`;
- `docs/tls.md`;
- `docs/compression.md`;
- architecture/benchmark docs when their contract changes.

Document unsupported behavior explicitly.

Do not advertise future protocol support before it exists and is tested.

## Review checklist

Before approving protocol work, verify:

- the state machine has clear terminal ownership;
- malformed input follows the documented failure path;
- resource limits are enforced before unbounded accumulation;
- protocol negotiation is standards-consistent;
- unsupported capabilities are not advertised;
- event-loop/backpressure rules remain intact;
- TLS secret handling remains safe;
- OpenAPI matches runtime/validation contracts;
- compression preserves framing and validators;
- cross-module boundaries have tests;
- performance-sensitive changes have equivalent benchmarks.

## Stop conditions

Reject or redesign the change when:

- a happy-path test is the only protocol evidence;
- the implementation accepts ambiguous/malformed state to be "compatible";
- a WebSocket close/completion can fire twice;
- an extension is used without negotiation;
- OpenAPI documents behavior runtime validation does not share;
- TLS advertises a protocol the server cannot handle;
- compression changes strong-validator semantics incorrectly;
- streaming compression breaks backpressure or buffers without bound;
- an optimization changes externally visible wire/document semantics.
