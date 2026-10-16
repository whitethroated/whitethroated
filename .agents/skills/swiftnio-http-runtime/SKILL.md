# Skill: SwiftNIO HTTP runtime

Use this skill for `HTTPServerHandler`, ChannelHandlers, event loops, EventLoopFuture, connection lifecycle, streaming, backpressure, and transport writes.

## Core model

WhiteThroated is SwiftNIO-first.

The ordinary transport path should stay on the channel event loop and avoid Swift concurrency unless the user explicitly registered an async/await handler.

## Event-loop invariants

- Never block an event-loop thread.
- Never wait synchronously for an EventLoopFuture.
- Mutable ChannelHandler state is event-loop confined.
- A future that mutates channel-local state must execute on the owning event loop.
- Use `hop(to:)` only where ownership is not already guaranteed.
- Prefer isolated callbacks when the event-loop ownership invariant is established.
- Unsafe isolation is allowed only when the invariant is real, documented, and tested.

## Responder cost tiers

Keep these paths distinct:

1. Prepared: no Request construction when middleware is absent.
2. Synchronous: Request + direct Response.
3. NIO future: Request + Context + EventLoopFuture.
4. Async/await: Request + Swift Task bridge.

Never unify them behind a Task or future if that forces cheap paths to pay expensive-path overhead.

## Channel lifecycle

When modifying request lifecycle state, consider:

- head
- body chunks
- end
- keep-alive
- pipelining
- connection close
- failed writes
- asynchronous completion after request state reset

Do not keep references to mutable per-request state that may be overwritten before an async completion executes.

## Bodyless head dispatch

A head-only shortcut is safe only when framing proves the body is empty.

Check:

- no Transfer-Encoding
- Content-Length absent or exactly zero under the framework's accepted rules
- no feature requires waiting for end
- Expect behavior
- middleware and streaming requirements

Any ambiguous framing must use the general lifecycle.

## Futures

For already-succeeded event-loop futures:

- avoid unnecessary bridge layers
- avoid Context if the responder type does not require it
- avoid repeated generic match pattern extraction when a validated side cache can store the resolved handler

Do not assume a future is on the channel event loop unless construction or an explicit hop proves it.

## Swift concurrency

Async/await is an opt-in feature.

- Do not create a Task for sync or future handlers.
- Do not wrap an EventLoopFuture in Task merely for API uniformity.
- Bridge async handlers once, at the responder boundary.
- Preserve error propagation through the framework error path.

## Streaming

Request and response streaming must preserve:

- backpressure
- bounded buffering
- chunk order
- failure propagation
- finalization exactly once
- connection correctness after failure

Do not allocate an EventLoopFuture per chunk for synchronous chunk processing.

Feature registration should not impose bookkeeping on methods/routes that cannot use the feature.

## Writes and flushes

Flush behavior can dominate streaming latency and throughput.

- avoid gratuitous flushes
- preserve user-requested explicit flush semantics
- distinguish write cost from flush cost in benchmarks
- do not coalesce in a way that violates streaming API semantics

## Safety review

Any change to `HTTPServerHandler` should be reviewed for:

- event-loop confinement
- state reset ordering
- pipelined requests
- async completion races
- framing correctness
- keep-alive behavior
- memory retention
- write failure handling

Pair this skill with `http-correctness-security` and `benchmark-validation`.
