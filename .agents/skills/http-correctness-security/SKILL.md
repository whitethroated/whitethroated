# Skill: HTTP correctness and security

Use this skill whenever transport parsing, headers, framing, keep-alive, body limits, conditional responses, byte ranges, proxy trust, or response serialization changes.

## Rule

An optimized response is valid only if it is semantically equivalent and protocol-correct.

## Request framing

Review interactions among:

- Content-Length
- Transfer-Encoding
- duplicate Content-Length
- zero body
- chunked body
- Expect
- connection close
- pipelining

Do not invent permissive parsing that creates request-smuggling ambiguity.

When framing is ambiguous or invalid, prefer rejection or the established generic path over a speculative shortcut.

## Response framing

Ensure:

- Content-Length matches the actual body when present
- forbidden body statuses do not emit an illegal body
- HEAD suppresses body bytes while preserving appropriate metadata
- chunked encoding is used only when appropriate
- keep-alive semantics match HTTP version and Connection tokens
- cached response heads cannot retain stale per-request headers

## Header security

Never disable SwiftNIO response-header validation.

Reject or prevent CR/LF injection in convenience APIs.

Do not concatenate untrusted header values into raw HTTP bytes without validation.

## Body limits

Limits must be enforced before unbounded accumulation.

Review:

- declared Content-Length path
- chunked path
- aggregate body
- request streaming
- multipart parsing

Failure must not leave the connection state reusable in an unsafe or ambiguous way.

## Conditional requests

For ETag and related logic:

- preserve weak/strong comparison semantics
- normalize 304 responses correctly
- remove forbidden framing/body headers as required by existing behavior
- keep prepared fast paths equivalent to generic semantics

## Byte ranges

Validate:

- satisfiable ranges
- unsatisfiable ranges
- suffix ranges
- open-ended ranges
- content length
- Content-Range
- interaction with prepared bodies

Do not slice outside readable bounds.

## Proxy trust

The raw peer address remains authoritative unless an explicit trust policy says otherwise.

Forwarded-header processing must:

- be opt-in
- validate the direct peer
- walk hops according to the established right-to-left policy
- stop at untrusted or malformed hops
- avoid DNS resolution on the hot path

Never introduce a default trust-all mode.

## Streaming

Streaming APIs must bound memory and propagate failures.

A performance shortcut must not:

- drop chunks
- reorder chunks
- complete twice
- write after terminal failure
- ignore backpressure
- retain arbitrary request data after completion

## Security regression tests

When fixing a protocol/security bug, add the smallest test that demonstrates the previous dangerous behavior and proves the corrected behavior.
