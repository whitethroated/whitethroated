# WhiteThroated domain skill routing

Use this index when work touches an optional product, persistence, identity
state, portability boundary, or protocol contract.

The root `AGENTS.md` remains canonical. These domain skills complement the
existing runtime, routing, HTTP, testing, benchmark, and API skills.

Load only the skills that match the risk surface.

## Modular optional products

Use:

- `.agents/skills/modular-battery-design/SKILL.md`

For:

- adding a new optional SwiftPM product;
- changing dependency direction between optional modules and core;
- adding a shared core hook for optional capabilities;
- middleware/module installation behavior;
- setup-time vs request-time work;
- dependency policy for optional modules;
- proving disabled/idle/active overhead.

Common combinations:

```text
new optional module
  modular-battery-design
  api-ergonomics
  testing-regression
  benchmark-validation       if request-time work changes
```

## Data and persistence

Use:

- `.agents/skills/data-persistence/SKILL.md`

For:

- WhiteThroatedServices;
- WhiteThroatedDatabase;
- WhiteThroatedPostgres;
- WhiteThroatedMigrations;
- WhiteThroatedORM;
- connection pools;
- transactions;
- cancellation;
- query/value/row semantics;
- persistence lifecycle.

Common combinations:

```text
PostgreSQL adapter change
  data-persistence
  cross-platform-portability
  testing-regression
  benchmark-validation       when performance is claimed

ORM/API change
  data-persistence
  api-ergonomics
  testing-regression
```

## Identity and state security

Use:

- `.agents/skills/identity-state-security/SKILL.md`

For:

- WhiteThroatedAuth;
- WhiteThroatedSessions;
- WhiteThroatedRedisSessions;
- WhiteThroatedCSRF;
- WhiteThroatedAuthRateLimit;
- identity-aware rate limiting;
- credential parsing;
- cookie/session security;
- trusted client identity used for security decisions.

Common combinations:

```text
session/auth change
  identity-state-security
  http-correctness-security
  testing-regression

distributed/session-store change
  identity-state-security
  data-persistence          when persistence semantics apply
  testing-regression
  benchmark-validation      when request-time cost changes
```

## Cross-platform/system interfaces

Use:

- `.agents/skills/cross-platform-portability/SKILL.md`

For:

- Darwin/Glibc conditionals;
- sockets and C APIs;
- libpq;
- zlib;
- system-library targets;
- filesystem portability;
- descriptor/process/signal behavior;
- ARM64/x86_64 assumptions;
- Linux/macOS validation.

Common combinations:

```text
socket/runtime system change
  cross-platform-portability
  swiftnio-http-runtime
  testing-regression
  benchmark-validation      when performance changes

libpq/system database change
  cross-platform-portability
  data-persistence
  testing-regression
```

## External protocol contracts

Use:

- `.agents/skills/protocol-contracts/SKILL.md`

For:

- WhiteThroatedWebSocket;
- WhiteThroatedOpenAPI;
- WhiteThroatedTLS;
- WhiteThroatedCompression;
- HTTP upgrade behavior;
- protocol negotiation;
- externally visible schema/wire contracts.

Common combinations:

```text
WebSocket
  protocol-contracts
  swiftnio-http-runtime
  http-correctness-security
  testing-regression
  benchmark-validation      for performance work

Compression
  protocol-contracts
  http-correctness-security
  swiftnio-http-runtime     for streaming
  testing-regression
  benchmark-validation      for performance work

TLS
  protocol-contracts
  swiftnio-http-runtime
  cross-platform-portability
  testing-regression

OpenAPI
  protocol-contracts
  api-ergonomics
  testing-regression
```

## Multi-domain tasks

Use all applicable skills when a task crosses boundaries.

Examples:

### Add Redis-backed distributed rate limiting

```text
modular-battery-design
identity-state-security
data-persistence            for backend/atomicity/lifecycle semantics
testing-regression
benchmark-validation        for request-time overhead
```

### Add WebSocket per-message compression

```text
modular-battery-design
protocol-contracts
swiftnio-http-runtime
http-correctness-security
swift-runtime-performance
testing-regression
benchmark-validation
```

### Optimize PostgreSQL cancellation on Linux

```text
data-persistence
cross-platform-portability
testing-regression
swift-runtime-performance   only when local Swift costs are being changed
benchmark-validation        only for performance claims
```

### Add a new optional authentication adapter

```text
modular-battery-design
identity-state-security
api-ergonomics
testing-regression
cross-platform-portability  if system/platform interfaces are used
```

## Existing core skills remain mandatory when relevant

These domain skills do not replace:

- `swift-runtime-performance`;
- `swiftnio-http-runtime`;
- `routing-request-path`;
- `benchmark-validation`;
- `api-ergonomics`;
- `http-correctness-security`;
- `testing-regression`.

Examples:

- a database optimization that changes allocations still needs
  `swift-runtime-performance`;
- WebSocket transport work still needs `swiftnio-http-runtime`;
- auth changes involving headers/cookies still need
  `http-correctness-security`;
- every non-trivial implementation change still needs
  `testing-regression`;
- every measured performance claim still needs
  `benchmark-validation`.

## Routing principle

Choose skills by failure mode, not by filename count.

A task should load the smallest set that covers:

- architecture boundary;
- correctness/security boundary;
- concurrency/I/O boundary;
- portability boundary;
- benchmark claim.

Do not load every skill for every task.
