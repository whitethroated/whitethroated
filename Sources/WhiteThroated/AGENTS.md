# Runtime scoped instructions

These rules apply to `Sources/WhiteThroated/` and supplement the root `AGENTS.md`.

This directory is the framework hot path. Treat every per-request allocation, branch, copy, event-loop hop, future, Task, and header mutation as potentially significant until measured.

Before modifying runtime code, read `ARCHITECTURE.md` and the relevant skills.

Required skills by default:

- `.agents/skills/swift-runtime-performance/SKILL.md`
- `.agents/skills/swiftnio-http-runtime/SKILL.md` for transport/concurrency
- `.agents/skills/routing-request-path/SKILL.md` for routing/request lookup
- `.agents/skills/http-correctness-security/SKILL.md` for HTTP semantics

Rules:

- Preserve setup-time versus serving-time separation.
- Keep prepared, synchronous, future, and async/await responder costs distinct.
- Do not move work from setup to the request path without a strong reason.
- Do not introduce implicit Task creation.
- Do not introduce blocking operations.
- Prefer lazy parsing and materialization.
- Preserve channel event-loop confinement.
- Any unsafe or unchecked construct needs a nearby invariant that makes it safe.
- Any new fast path needs an equivalent fallback path and tests proving semantic equivalence.
- Any request-hot-path change requires benchmark validation before a performance claim.

Update `ARCHITECTURE.md` if the runtime path or invariant changes.
