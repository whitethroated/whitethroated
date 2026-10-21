# WhiteThroatedRateLimit

Status: **experimental**

`WhiteThroatedRateLimit` is an opt-in fixed-window rate limiter with bounded
in-process state. Importing the product does not install middleware or change
WhiteThroated core/runtime behavior.

## Basic use

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

let app = Application()
app.use(rateLimiter: limiter)
```

The key resolver is required. The module deliberately provides no implicit
client-IP or `X-Forwarded-For` resolver. Applications behind a proxy must
establish an explicit trusted-proxy policy before deriving a limiter key from
forwarded headers.

Do not use secrets such as raw bearer tokens as long-lived keys. Prefer a
bounded opaque identifier or a derived value that is safe to retain in process
memory.

## Bounded state

The local store is bounded by two independent limits:

- `maxKeys`: maximum number of simultaneously retained limiter keys;
- `maxKeyBytes`: maximum UTF-8 size of one key.

When a new valid key arrives at capacity, the least-recently-touched key is
evicted. Missing, empty, or oversized keys never enter the store.

`RateLimitKeyFailureBehavior` makes failure handling explicit:

- `.reject` (default) returns `429 Too Many Requests`;
- `.passThrough` delegates to the next responder without creating state.

This store is process-local. It is not a distributed quota and should not be
presented as globally consistent when multiple application processes are
serving the same logical client.

## Response fields

With `emitHeaders: true` (default), accepted responses receive:

- `RateLimit-Limit`;
- `RateLimit-Remaining`;
- `RateLimit-Reset` as seconds until the current fixed window resets.

Rejected requests also receive `Retry-After`.

Adding per-request rate-limit fields requires a mutable response. Therefore an
active limiter with `emitHeaders: true` converts a prepared downstream
response into a normal response. Set `emitHeaders: false` when preserving the
prepared-response fast path is more important than emitting accepted-request
quota fields; rejected requests still return their rejection metadata.

## Concurrency model

The in-memory store uses a SwiftNIO lock-protected dictionary. No `Task`,
actor hop, future, or event-loop hop is introduced by the limiter. Only routes
behind the explicitly installed limiter execute the key resolver and acquire
the store lock.

A deterministic `RateLimitClock` can be injected for tests. The production
default uses monotonic uptime nanoseconds rather than wall-clock time, so clock
adjustments do not move an active window backward or forward.

## Current boundaries

This experimental slice intentionally includes only a bounded local
fixed-window limiter. It does not yet provide:

- sliding-window or token-bucket algorithms;
- Redis/database/distributed stores;
- trusted-proxy parsing;
- automatic principal or API-key integration;
- distributed-store fail-open/fail-closed policy.

Those capabilities require separate contracts because they introduce network,
atomicity, proxy-trust, or concurrency semantics that should not be hidden
behind this local synchronous fast path.

## Benchmark status

No performance claim is made yet. Before promotion beyond experimental, record
the roadmap's three conditions independently:

1. module not linked/disabled;
2. module linked but limiter not installed on the route;
3. limiter active with semantically equivalent controls.

At minimum record RPS, completed requests, errors, p50/p90/p99/p99.999/max,
and peak RSS for the active bounded-state matrix.
