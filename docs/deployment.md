# Production deployment

Status: **experimental**

WhiteThroated ships a lifecycle-aware deployment example and validates its
process contract on Linux CI. This document separates that validated contract
from infrastructure recipes that still require environment-specific validation.

## Validated deployment contract

The `whitethroated-deployment-example` executable is built in release mode and
started inside the CircleCI Linux validation container. CI verifies all of the
following through the real TCP listener:

- the process starts on the configured host and port;
- `GET /ready` returns `200` with `ready` before draining;
- `GET /health` returns `200` with `ok`;
- `GET /` returns the expected application response;
- the process receives `SIGTERM`;
- the signal initiates `LifecycleController.shutdown`;
- the listener closes and the process exits successfully within the CI bound.

The CI environment is the official `swift:6.4.0-noble` container. This is a
compatibility and deployment-contract check, not performance evidence and not a
claim that a particular container platform, init system, load balancer, or
reverse proxy has been production-certified.

## Build and run

Build the validated deployment example:

```text
swift build -c release --product whitethroated-deployment-example
```

Run it:

```text
WHITETHROATED_HOST=0.0.0.0 \
WHITETHROATED_PORT=3000 \
WHITETHROATED_DRAIN_TIMEOUT_SECONDS=30 \
  .build/release/whitethroated-deployment-example
```

The example reads only setup-time process configuration.

| Variable | Default | Contract |
| --- | --- | --- |
| `WHITETHROATED_HOST` | `0.0.0.0` | Listener bind address. |
| `WHITETHROATED_PORT` | `3000` | TCP port in `1...65535`. Invalid values fail startup. |
| `WHITETHROATED_DRAIN_TIMEOUT_SECONDS` | `30` | Maximum drain wait before teardown, bounded to `0...3600`. |

Applications should parse and validate their own configuration before calling
`listen` or `run`. Do not defer configuration discovery to request time.

## Health and readiness

Use health and readiness for different questions:

- `/health` answers whether the process is alive enough to serve its basic
  application contract.
- `/ready` answers whether the lifecycle controller is accepting new traffic.

The deployment example installs `WhiteThroatedLifecycle` before registering
its routes. Once draining starts, new requests are rejected with
`503 Service Unavailable`. Requests that entered before draining are counted
until their immediate, prepared, or future response completes.

A load balancer or orchestrator should stop routing new traffic to an instance
when readiness fails.

## Graceful termination

WhiteThroated deliberately does not install global process signal handlers in the
core framework. The embedding application owns process signals.

The validated deployment example owns `SIGTERM` and `SIGINT` with
`DispatchSource`. On either signal it calls:

```swift
try await lifecycle.shutdown(
    application: app,
    drainTimeoutNanoseconds: drainTimeout
)
```

Shutdown performs this sequence:

1. transition from accepting to draining;
2. reject new lifecycle-managed requests;
3. wait for active requests until the configured drain deadline;
4. run registered cleanup callbacks in reverse order;
5. stop the WhiteThroated application and listener;
6. mark the lifecycle controller stopped.

Choose the drain timeout so it is no longer than the deployment platform's
termination grace period. Cleanup callbacks that perform I/O need their own
bounded timeout.

## Reverse-proxy termination

For a same-host reverse proxy, bind WhiteThroated to a private listener such as
`127.0.0.1:3000` and expose only the proxy publicly.

Example application launch:

```text
WHITETHROATED_HOST=127.0.0.1 \
WHITETHROATED_PORT=3000 \
  .build/release/my-service
```

TLS termination at the proxy does not make forwarding headers trustworthy.
Client IP, scheme, or host information derived from forwarded headers must use
an explicit `TrustedProxy` policy. Never enable a trust-all forwarded-header
policy.

The repository does not currently run a reverse proxy in the deployment smoke,
so proxy-specific configuration remains an infrastructure recipe rather than a
validated WhiteThroated CI contract.

## Direct TLS

Applications may terminate TLS inside WhiteThroated with
`WhiteThroatedTLS`. Certificate and private-key loading happens during setup,
not on an event loop.

See `docs/tls.md` for the supported TLS contract, minimum version, ALPN
restrictions, and certificate rotation model.

Direct TLS is covered by module tests, but the deployment process smoke does not
perform an external TLS handshake. Do not describe the deployment example as a
full TLS deployment certification.

## Secrets and configuration

Treat credentials independently from ordinary process configuration.

Recommended boundaries:

- inject database credentials from the deployment platform's secret store;
- mount TLS private keys as secret files or supply already-loaded PEM bytes;
- do not commit secrets into the repository or container image;
- do not print authorization headers, cookies, private keys, or database
  passwords;
- prefer environment variables or secret-file paths over command-line secret
  arguments, because command lines may be visible through process inspection;
- validate required configuration before opening the listener.

The PostgreSQL migration CLI accepts `DATABASE_URL` or
`WHITETHROATED_DATABASE_URL`. See `docs/migrations.md`.

## Migrations

Migrations are explicit and forward-only. They do not run automatically when the
server starts.

A conservative rollout sequence is:

```text
.build/release/whitethroated-migrate --status
.build/release/whitethroated-migrate --dry-run
.build/release/whitethroated-migrate
```

Run migrations with the same migration set and database configuration intended
for the release. The migration runner uses checksums and locking to prevent
silent history drift and concurrent migration interleaving.

Because down migrations are not supported, application rollback must account for
schema compatibility. Prefer expand/contract schema changes when a previous
binary may need to run against the new schema.

## Rollout

A production rollout should follow this order:

1. build and identify the exact release artifact and commit;
2. validate required secrets and configuration;
3. inspect and apply compatible migrations;
4. start the new instance;
5. wait for `/ready` to return success;
6. run an application-specific smoke request;
7. add the new instance to traffic;
8. remove the old instance from new traffic;
9. send `SIGTERM` to the old instance;
10. verify the old instance exits within the termination grace period;
11. observe errors, latency, resource use, and downstream health.

Do not send traffic merely because the process exists. Readiness is the serving
gate.

## Rollback

Before every rollout, decide whether the previous application version remains
compatible with the post-migration schema.

If it is compatible:

1. stop routing traffic to the new instance;
2. start or restore the previous binary;
3. wait for readiness;
4. shift traffic back;
5. drain the failed release.

If the schema is not backward-compatible, do not blindly restore the previous
binary. Apply a new forward migration or deploy a compatibility release first.

WhiteThroated's migration checksums protect migration history; they are not an
automatic rollback system.

## Observability

Production applications should install only the observability capabilities they
need:

- `WhiteThroatedLogging`;
- `WhiteThroatedMetrics`;
- `WhiteThroatedTracing`.

Keep labels bounded, avoid credentials and sensitive bodies, and keep exporters
off event-loop threads. See `docs/observability.md`.

During rollout, monitor at least:

- readiness failures;
- HTTP error rate;
- request latency;
- process restarts/exits;
- database or downstream errors;
- CPU and memory pressure.

## Operational checklist

Before deployment:

- [ ] release build produced from the intended commit;
- [ ] release tests are green;
- [ ] required configuration parses successfully;
- [ ] secrets are provided outside source control;
- [ ] migration status and dry run were reviewed;
- [ ] schema changes are compatible with the rollback plan;
- [ ] readiness and health endpoints are configured;
- [ ] drain timeout fits the platform termination grace period;
- [ ] database pools/exporters have lifecycle cleanup hooks;
- [ ] proxy trust policy is explicit when forwarded headers are used;
- [ ] TLS ownership and certificate rotation are documented;
- [ ] logs/metrics/traces avoid unbounded or sensitive values.

During rollout:

- [ ] new instance reaches readiness before receiving traffic;
- [ ] application smoke request succeeds;
- [ ] traffic shift does not produce an error/latency regression;
- [ ] old instance is removed from traffic before termination;
- [ ] old instance exits within the drain/grace deadline.

After rollout:

- [ ] migration state is recorded;
- [ ] error rate and tails remain acceptable;
- [ ] no restart loop or resource leak is visible;
- [ ] rollback compatibility is still understood for the next release.

## What CI does not prove

The Linux deployment smoke does **not** prove:

- production throughput or p90/p99 latency;
- Kubernetes behavior;
- systemd behavior;
- a specific cloud load balancer;
- reverse-proxy configuration;
- external TLS handshake/certificate rotation;
- database failover;
- exporter/network failure handling.

Those environments need their own validation before being documented as
production-tested. Performance claims continue to follow
`BENCHMARKS.md` and `docs/linux-validation-checklist.md`.
