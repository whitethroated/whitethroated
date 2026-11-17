# Contributing to WhiteThroated

WhiteThroated is pre-alpha and welcomes careful contributions. API
stability is intentionally secondary to establishing a fast, measurable
runtime — expect breaking changes before 1.0.

## Ground rules

- All implementation, test, example, and benchmark sources are Swift.
  Do not add Python, JavaScript, Rust, C, shell, or other source files
  to implement or benchmark the framework.
- Read [AGENTS.md](AGENTS.md) before changing anything, then
  [ARCHITECTURE.md](ARCHITECTURE.md) for runtime work and
  [BENCHMARKS.md](BENCHMARKS.md) for performance work.
- Correctness and benchmark integrity outrank speed. Never trade HTTP
  correctness, header validation, body limits, proxy trust, or
  event-loop safety for throughput.
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Environment

- Swift 6.4, SwiftPM tools 6.1+.
- The optional PostgreSQL tests need `libpq` and `pkg-config`
  (`apt install libpq-dev pkg-config` on Debian/Ubuntu).
- Keep dependencies pinned; do not upgrade SwiftNIO casually.

## Workflow

1. Fork and branch from `main`; keep branches short-lived and focused.
2. Run targeted tests while iterating, then the full release suite:
   `swift test -c release`.
3. Build affected products, e.g.
   `swift build -c release --product whitethroated-example`.
4. Run the secret-hygiene checks before every commit
   (`.agents/skills/secret-hygiene/SKILL.md`): noreply identity, no
   credentials or personal emails in the diff.
5. Open a pull request against `main`. CI must be green.

## Tests

- Every bug fix needs a regression test.
- Every new fast path needs hit, miss/fallback, boundary, and
  invalidation coverage with semantics equivalent to the generic path.
- Match the existing Swift test style and nearby helpers.

## Performance changes

- Measure before and after in release mode on the same machine, with
  identical requests, concurrency, and warm-up; follow BENCHMARKS.md.
- Report requests/s plus p50/p90/p99 (and max) latency. Within noise
  means neutral, not faster.
- Never special-case a benchmark request in a way real applications
  cannot use.

## Style

- There is no formatter config yet: match the surrounding file and keep
  commits focused with no unrelated refactors.
- Public API should feel small and Swift-native; avoid conveniences
  that silently add a Task, lock, copy, or global sync per request.

## Issues

Include the commit hash, platform (`swift --version` plus OS), minimal
reproduction, and expected vs actual behavior. For suspected
vulnerabilities use [SECURITY.md](SECURITY.md), never a public issue.

## License

Contributions are accepted under the Apache License, Version 2.0; by
submitting a pull request you agree your work is licensed that way.
