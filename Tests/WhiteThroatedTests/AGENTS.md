# Test scoped instructions

These rules apply to `Tests/WhiteThroatedTests/` and supplement the root `AGENTS.md`.

Read `.agents/skills/testing-regression/SKILL.md` before substantial test changes.

Rules:

- Match the established Swift test style in adjacent files.
- Prefer deterministic assertions over sleeps and timing thresholds.
- Every optimized path needs tests for hit, invalidation, and fallback behavior.
- Transport changes need malformed-input and lifecycle edge cases where relevant.
- Router changes need static/parameter/catch-all precedence coverage and cache invalidation coverage.
- Streaming changes need chunk, completion, failure, limit, and backpressure-related coverage where applicable.
- Security fixes require regression tests reproducing the previous vulnerability or ambiguity.
- Diagnostic microbenchmarks must remain opt-in through environment variables.
- Do not turn shared-runner ns/op into a test threshold.
- Do not reduce test strictness to accommodate a fast path; fix the implementation.
