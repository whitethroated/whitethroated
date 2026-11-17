# WhiteThroated docs index

Start with the root documents, then the guide for the area you need.
Dated `benchmark-*` reports are point-in-time measurements, not living
specs; read `performance-goal-status.md` first for the current verdict.

## Entry points

- [README.md](../README.md) — quick start, modules, transport, benchmark commands.
- [ARCHITECTURE.md](../ARCHITECTURE.md) — runtime invariants (authoritative for runtime work).
- [BENCHMARKS.md](../BENCHMARKS.md) — benchmark protocol, controls, and metrics.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — contributor workflow.
- [performance-goal-status.md](performance-goal-status.md) — current performance verdict.

## Module and operations guides

- [cors.md](cors.md) — CORS security and caching behavior.
- [static-files.md](static-files.md) — static files security, lifecycle, limits.
- [validation.md](validation.md) — validation error model and cost model.
- [rate-limit.md](rate-limit.md) — rate-limit trust boundary and state bounds.
- [observability.md](observability.md) — logging, metrics, tracing.
- [lifecycle.md](lifecycle.md) — application lifecycle.
- [identity-state.md](identity-state.md) — auth, sessions, CSRF.
- [data-services.md](data-services.md) — database, Postgres, ORM.
- [migrations.md](migrations.md) — migration CLI and history.
- [compression.md](compression.md) — response compression.
- [tls.md](tls.md) — direct TLS termination.
- [websocket.md](websocket.md) — WebSocket support.
- [openapi.md](openapi.md) — OpenAPI generation.
- [deployment.md](deployment.md) — production deployment.
- [circleci.md](circleci.md) — CircleCI validation mirror.
- [linux-validation-checklist.md](linux-validation-checklist.md) — Linux CI evidence.

## Roadmap

- [plan/modular-batteries-roadmap.md](plan/modular-batteries-roadmap.md) — optional-module roadmap.

## Benchmark reports

Dated reports (`benchmark-*.md`) with raw data in
[benchmark-data/](benchmark-data/). Each report states its hardware,
commit, and verdict; newer reports supersede older ones on the same
question.
