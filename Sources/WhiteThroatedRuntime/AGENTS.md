# Runtime scoped instructions

These rules apply to `Sources/WhiteThroatedRuntime/` and supplement the root `AGENTS.md`.

This directory is the HTTP execution layer. It owns bootstrap, the HTTP/1.1 pipeline, request dispatch state, body mechanics, the response writer, keep-alive, and backpressure — and nothing else.

Before modifying runtime code, read `ARCHITECTURE.md` and the relevant skills.

Required skills by default:

- `.agents/skills/swift-runtime-performance/SKILL.md`
- `.agents/skills/swiftnio-http-runtime/SKILL.md` for transport/concurrency
- `.agents/skills/http-correctness-security/SKILL.md` for HTTP semantics

Rules:

- Do not add framework concepts here: no route registration, route groups, middleware composition, JSON/cookie/ETag helpers, or developer convenience APIs.
- Keep the `RuntimeDispatcher` bridge concrete: no protocols, existentials, type erasure, or per-request allocations.
- Keep synchronous dispatch synchronous: no `Task`, no futures, no promises, no event-loop hops on the sync path.
- A request stays on its connection event loop unless explicit async work requires otherwise; document every new hop-off point.
- Do not introduce locks, global pools, or shared mutable state. Reusable storage must be connection-, channel-, or event-loop-owned.
- Do not add timer-based batching or intentionally delay responses.
- Preserve setup-time versus serving-time separation.
- Preserve channel event-loop confinement.
- Any unsafe or unchecked construct needs a nearby invariant that makes it safe.
- Any new fast path needs an equivalent fallback path and tests proving semantic equivalence.
- Any request-hot-path change requires benchmark validation before a performance claim.

Update `ARCHITECTURE.md` if the runtime path or invariant changes.
