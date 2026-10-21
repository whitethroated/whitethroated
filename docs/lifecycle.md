# WhiteThroatedLifecycle

Status: **experimental**

`WhiteThroatedLifecycle` coordinates readiness, request draining, cleanup, and
the existing WhiteThroated server shutdown.

```swift
import WhiteThroated
import WhiteThroatedLifecycle

let lifecycle = LifecycleController()
let app = Application()

app.use(
    lifecycle: lifecycle,
    readinessPath: "/ready"
)

lifecycle.registerCleanup {
    // Close application-owned resources here.
}
```

While the controller is accepting traffic, the readiness endpoint returns
`200`. Calling `beginDrain()` immediately changes readiness to `503` and
new requests entering the lifecycle middleware are rejected with
`503 Service Unavailable`.

Requests that entered before draining started remain counted until their
immediate/prepared/future result completes. `shutdown(application:...)` waits
for the active count to reach zero or for the configured drain timeout to
expire, then runs cleanup callbacks in reverse registration order and invokes
the application's existing shutdown path.

The drain wait is shutdown-only work and does not create per-request
`Task`/future hops. Request accounting uses a small lock-protected counter.

## Operational boundary

The experimental controller is process-local. Readiness should be removed from
load-balancer traffic before shutdown is initiated. Cleanup callbacks are
synchronous in this slice; network-backed services should expose a synchronous
shutdown barrier or receive a dedicated asynchronous lifecycle adapter in a
later revision.

Signal handling is intentionally not installed automatically. Embedders and test
hosts retain ownership of process signals.

No claim is made that the default timeout fits every workload. Choose a value
consistent with upstream request deadlines and deployment termination grace
periods.
