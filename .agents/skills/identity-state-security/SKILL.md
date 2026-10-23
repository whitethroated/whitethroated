# Skill: identity and state security

Use this skill whenever changing authentication, authorization, sessions, CSRF,
rate limiting keyed by identity, trusted client identity, cookies, credentials,
or security-sensitive request state.

Typical scope includes WhiteThroatedAuth, WhiteThroatedSessions,
WhiteThroatedRedisSessions, WhiteThroatedCSRF, WhiteThroatedAuthRateLimit, and
identity-aware rate limiting.

## Principle

Authentication, authorization, and session state are separate security
boundaries.

Do not collapse them into one implicit concept.

Use these questions explicitly:

- Authentication: who or what presented credentials?
- Authorization: is that principal permitted to perform this action?
- Session: what server/client state represents continuity across requests?
- CSRF: can another origin cause an authenticated browser action?
- Rate limiting: what trustworthy identity is being limited?

A valid credential does not imply authorization.

A session identifier is not inherently a principal.

A client IP is not trustworthy when derived from an untrusted forwarded header.

## Secure failure behavior

When identity or state cannot be validated safely, fail according to the
documented policy rather than guessing.

Do not:

- silently authenticate malformed credentials;
- fall back from strong validation to permissive parsing;
- convert authorization failure into authentication success;
- trust forwarded identity without a trusted-proxy policy;
- continue using session state whose integrity cannot be established;
- expose secret values in error responses or logs.

Keep 401 and 403 semantics deliberate and consistent with the public API.

## Credential handling

Treat these values as secrets:

- passwords;
- bearer tokens;
- API keys;
- session IDs;
- refresh tokens;
- CSRF secrets;
- signing/encryption keys;
- Authorization and Cookie headers.

Do not log them by default.

Avoid including them in metric labels, trace attributes, structured errors, or
debug descriptions.

Use maintained cryptographic primitives. Do not design custom password hashing,
MAC, signature, encryption, or token formats without an explicit cryptographic
design review.

Compare secret-derived authenticators using constant-time primitives when the
representation and library permit it.

## Authentication contract

An authenticator should make clear:

- which credential type it accepts;
- whether it performs I/O;
- whether it can block;
- what principal shape it returns;
- how malformed vs missing credentials differ;
- whether credentials are single-use, renewable, or replayable;
- how expiration is evaluated;
- what clock assumptions exist.

Do not make synchronous authentication APIs secretly perform blocking network or
database I/O.

If authentication needs async I/O, expose an execution model that makes that
cost visible.

## Authorization contract

Authorization must evaluate policy against a principal and resource/context.

Do not encode authorization solely as:

- route existence;
- successful authentication;
- possession of a session cookie;
- client-side UI state;
- a raw role string without a defined policy.

When roles or permissions are introduced, define:

- precedence;
- inheritance if any;
- default deny behavior;
- missing principal behavior;
- resource ownership semantics.

Prefer policy evaluation that is deterministic and testable.

## Session lifecycle

A session system must define:

- creation;
- loading;
- rotation;
- expiration;
- idle timeout if supported;
- destruction/logout;
- store failure;
- key rotation;
- concurrent request behavior.

Rotate the session identifier after authentication or privilege elevation when
session fixation is relevant.

Destroying a session must make subsequent use fail according to the documented
consistency model.

Do not reuse a session ID after privilege changes merely to save a store write.

## Session cookies

Cookie defaults and configuration must make security properties explicit.

Review applicable attributes:

- HttpOnly;
- Secure;
- SameSite;
- Path;
- Domain;
- Max-Age/Expires;
- host-only semantics;
- prefix requirements such as __Host- or __Secure- when used.

Do not disable HttpOnly or Secure merely to make local tests convenient.

When direct TLS is not used, determine secure-cookie behavior from the
application's trusted deployment configuration, not arbitrary spoofable
forwarded headers.

Avoid setting a broad Domain unless cross-host sharing is intentional.

## Session storage

Session storage may be local or distributed, but the contract must define
consistency and failure behavior.

For distributed stores:

- keep network I/O off event-loop-blocking paths;
- define timeout behavior;
- define what happens when the store is unavailable;
- avoid unbounded retry loops;
- preserve TTL semantics;
- avoid extending expiration accidentally on reads unless idle-expiration policy
  says to do so.

Memory stores are useful for tests/development but must not be presented as
multi-process production-safe.

## Redis-backed state

For Redis session or rate-limit adapters, make explicit:

- key namespace;
- TTL;
- atomicity requirements;
- serialization format/versioning;
- failure policy;
- reconnect behavior;
- maximum stored value size.

Do not implement multi-step security decisions with non-atomic commands when a
race can violate the policy.

A fail-open/fail-closed choice must be documented; it must not emerge
accidentally from exception handling.

## CSRF boundary

CSRF protection applies primarily to browser credentials that are sent
automatically, especially cookies.

Do not require CSRF tokens for stateless bearer-token APIs solely because they
are authenticated.

For a CSRF mechanism, define:

- protected methods;
- token source;
- cookie/session relationship;
- token comparison;
- rotation behavior;
- Origin/Referer validation if used;
- handling of missing headers;
- trusted proxy interaction when scheme/host matters.

Safe-method exemptions must be explicit and tested.

Do not treat CORS as a replacement for CSRF protection.

## Rate-limit identity

A limiter is only as trustworthy as its key.

Potential keys include:

- authenticated principal;
- API key identity;
- trusted client IP;
- application-provided stable identifier.

Do not use X-Forwarded-For or similar headers directly unless TrustedProxy has
validated the chain.

Define whether rate limits are:

- per process;
- per node;
- distributed;
- per principal;
- per route/policy.

Distributed limiter operations that require atomic counters/buckets must use a
backend operation with equivalent atomicity.

## Trusted proxy boundary

The socket peer is the default network identity.

Forwarded client IP, scheme, and host become trustworthy only after explicit
proxy validation.

When processing proxy chains:

- validate the direct peer first;
- follow the established hop policy;
- stop at malformed or untrusted hops;
- do not perform DNS resolution on the hot path;
- do not trust an arbitrary leftmost address.

Identity-sensitive security logic must not bypass the repository's TrustedProxy
policy.

## Token expiration and clocks

Token/session expiration code must define its clock source and boundary
semantics.

Test:

- just before expiry;
- exactly at expiry;
- just after expiry;
- invalid timestamps;
- excessive future timestamps when relevant.

Avoid wall-clock-dependent flaky tests; inject or control the clock when
possible.

Do not add large undocumented clock-skew windows to make tests pass.

## Key rotation

Signed/encrypted session or token formats need an intentional rotation story.

Prefer configurations that can distinguish:

- active signing/encryption key;
- accepted previous verification/decryption keys;
- retirement.

Do not silently discard all existing sessions during a key change unless that is
the explicit policy.

Do not keep retired verification keys forever.

## Replay and one-time credentials

When a credential is supposed to be one-time or replay-resistant, define the
server-side state or cryptographic mechanism that enforces this property.

Do not claim replay protection merely because a token expires quickly.

For password reset, email verification, nonce, or similar future capabilities,
separate:

- possession;
- expiration;
- one-time consumption;
- privilege change.

## Error and observability discipline

Security logs may record:

- policy name;
- route label;
- high-level failure category;
- stable non-secret principal identifier when policy explicitly permits it.

Do not record raw:

- credentials;
- cookies;
- session IDs;
- CSRF tokens;
- Authorization headers;
- password inputs.

Metrics should use bounded-cardinality labels.

Avoid returning detailed authentication failure reasons that create unnecessary
credential/user enumeration when the public API does not require them.

## Concurrency and state races

Identity/state features often involve concurrent requests.

Test races around:

- session rotation;
- logout vs in-flight request;
- rate-limit updates;
- key rotation;
- store expiration;
- privilege changes.

Do not use a mutable global dictionary without synchronization or confinement.

Synchronization added for security state must not block event loops.

## Validation and parsing

Credential parsers must be strict enough to avoid multiple interpretations.

Review:

- duplicate Authorization headers;
- whitespace normalization;
- malformed schemes;
- duplicate cookies;
- invalid encodings;
- oversized credential values;
- empty tokens;
- case sensitivity required by the relevant protocol.

Do not accept two contradictory credential sources without a defined precedence
policy.

## Testing strategy

Use deterministic tests for:

- missing credentials;
- valid credentials;
- malformed credentials;
- expired credentials;
- authentication success/failure;
- authorization allow/deny;
- 401/403 behavior;
- session create/load/rotate/destroy;
- fixation resistance;
- cookie attributes;
- store outage/failure policy;
- CSRF missing/wrong/correct token;
- safe method behavior;
- cross-origin behavior where relevant;
- rate-limit boundary;
- spoofed forwarded address;
- trusted proxy behavior;
- concurrent state transitions.

For cryptographic or serialization formats, include tamper tests.

For security bug fixes, keep a regression test that demonstrates the previous
unsafe behavior.

## Performance

Security checks must remain correct before they are fast.

Use `.agents/skills/benchmark-validation/SKILL.md` when changing request-time
identity/state behavior materially.

Measure at least the relevant distinction between:

- feature not installed;
- feature installed but no credential/state lookup required;
- authentication/session/rate-limit active.

Do not cache authorization or identity across requests unless the cache key and
invalidation rules prove the result is valid for the exact request/security
context.

Never weaken credential validation to improve benchmark numbers.

## Review checklist

Before approving identity/state work, verify:

- authentication and authorization remain separate;
- credentials are not logged;
- session fixation is handled where applicable;
- cookie security attributes remain deliberate;
- session store failure semantics are defined;
- CSRF is applied to the right credential model;
- forwarded identity is trusted only through TrustedProxy;
- rate-limit keys cannot be trivially spoofed;
- cryptographic primitives are maintained and standard;
- expiration boundaries are tested;
- concurrency races cannot resurrect invalid state;
- failure responses do not expose unnecessary secrets;
- request-time performance changes have evidence.

## Stop conditions

Reject or redesign the change when:

- authentication implicitly grants authorization;
- session IDs survive privilege elevation without justification;
- raw credentials appear in logs or metrics;
- spoofable forwarded headers drive security decisions;
- CSRF is replaced with CORS;
- distributed security state relies on non-atomic updates that violate policy;
- store failure accidentally changes fail-open/fail-closed behavior;
- token validation becomes permissive for benchmark convenience;
- blocking auth/session I/O can run on an event loop;
- a cache can reuse identity/authorization across an invalid context.
