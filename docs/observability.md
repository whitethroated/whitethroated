# WhiteThroated observability modules

Status: **experimental**

WhiteThroated keeps request instrumentation outside the core request path. Phase 2
ships three independent products so applications can enable only the signals they
need:

- `WhiteThroatedLogging`
- `WhiteThroatedMetrics`
- `WhiteThroatedTracing`

None of these products activates automatically when linked.

## Structured logging

```swift
import WhiteThroated
import WhiteThroatedLogging

let logger = StructuredRequestLogger(
    routeResolver: { request in
        request.path.hasPrefix("/users/")
            ? "/users/:id"
            : nil
    },
    sink: { event in
        print(event)
    }
)

app.use(structuredLogger: logger)
```

The default request-ID policy accepts only printable ASCII values up to a
configured byte limit. Missing or unsafe incoming IDs are replaced by the
configured generator.

The built-in event deliberately excludes request/response bodies, cookies,
authorization headers, and arbitrary headers. Applications that need additional
fields should construct them explicitly in their sink and apply their own
redaction policy.

Logging observes prepared responses without converting them into mutable
responses.

## Metrics

```swift
import WhiteThroatedMetrics

let metrics = HTTPMetrics(
    configuration: HTTPMetricsConfiguration(
        allowedRoutes: [
            "/users/:id",
            "/health",
        ],
        routeClassifier: { request in
            if request.path.hasPrefix("/users/") {
                return "/users/:id"
            }

            if request.path == "/health" {
                return "/health"
            }

            return nil
        }
    )
)

app.use(metrics: metrics)
```

The route classifier cannot create unbounded metric cardinality. Returned labels
are checked against `allowedRoutes`; every other value is collapsed into one
fixed unknown label. Custom HTTP methods are similarly collapsed to `OTHER`.

Snapshots include request count, status class, total latency, fixed latency
histogram buckets, known response bytes, and a count of responses whose length
was not known from headers.

Never use raw URI, query strings, user IDs, request IDs, or other
high-cardinality identifiers as metric labels.

## Tracing

```swift
import WhiteThroatedTracing

let tracer = ServerTracer(
    routeResolver: { request in
        request.path == "/health"
            ? "/health"
            : nil
    },
    sink: { span in
        print(span)
    }
)

app.use(tracer: tracer)
```

The server parser accepts strict W3C `traceparent` version `00` values and
rejects malformed or all-zero trace/span identifiers. The default sampler is
parent-based: an incoming sampled parent remains sampled; requests without a
valid parent are sampled.

Sampling is decided before route resolution and identifier generation so
unsampled requests do not construct expensive span attributes.

The built-in tracer emits completed server-span records to a local sink. Network
exporters are intentionally separate adapters and must not block event loops.

## Cost model

- Product not linked: zero module bookkeeping.
- Product linked but middleware not installed: zero module request work.
- Installed logging/tracing: one middleware layer plus configured sink work.
- Installed metrics: one middleware layer plus one lock-protected aggregate
  update per completed request.

All three observers preserve prepared responses because they only inspect
read-only prepared-response metadata.
