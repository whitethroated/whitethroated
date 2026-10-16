# Benchmark scoped instructions

These rules apply to `Benchmarks/` and supplement the root `AGENTS.md`.

Read `BENCHMARKS.md` and `.agents/skills/benchmark-validation/SKILL.md` before changing benchmark code.

The benchmark programs exist to measure WhiteThroated honestly, not to maximize a headline.

Rules:

- Benchmark implementation in this repository remains Swift-only.
- Keep request/response semantics identical across compared servers.
- Keep raw SwiftNIO a minimal but fair lower-bound control.
- Do not deliberately handicap raw SwiftNIO.
- Do not add framework-only prepared behavior to an external-contract comparison unless the compared framework gets equivalent setup-time preparation.
- Keep throughput-only and latency-enabled runs separate when latency collection changes load-generator overhead.
- Keep benchmark-only feature routes opt-in when their registration would tax the default route table or transport.
- Report enough metadata to reproduce a run.
- Never embed an unverified leaderboard claim in source or docs.
- If a control changes, refresh the baseline before interpreting production changes.

Benchmark smoke tests in CI verify harness integrity only. GitHub-hosted runner timing is not publication-grade evidence.
