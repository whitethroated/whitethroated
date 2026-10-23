# WhiteThroated agent skills

The root `AGENTS.md` is the canonical instruction set. Skills in this directory are task-specific playbooks.

Agents should load only the skills relevant to the files and risk surface being changed.

## Skill routing

- Runtime allocation, ARC, COW, strings, buffers, specialization:
  - `skills/swift-runtime-performance/SKILL.md`
- SwiftNIO transport, event loops, futures, streaming:
  - `skills/swiftnio-http-runtime/SKILL.md`
- Router lookup, parameters, route caches:
  - `skills/routing-request-path/SKILL.md`
- Benchmark design, controls, metrics, acceptance:
  - `skills/benchmark-validation/SKILL.md`
- Public API and Express-inspired ergonomics:
  - `skills/api-ergonomics/SKILL.md`
- HTTP framing, validation, protocol security:
  - `skills/http-correctness-security/SKILL.md`
- Tests and regression coverage:
  - `skills/testing-regression/SKILL.md`

## Common combinations

Transport optimization:
runtime-performance + swiftnio-http-runtime + http-correctness-security + benchmark-validation + testing-regression.

Router optimization:
runtime-performance + routing-request-path + benchmark-validation + testing-regression.

New public route API:
api-ergonomics + routing-request-path + testing-regression; add benchmark-validation if request-time behavior changes.

Streaming work:
swiftnio-http-runtime + http-correctness-security + runtime-performance + benchmark-validation + testing-regression.

## Repository integration

For branch creation, commits, pull requests, CI triage, merge readiness, and
parallel-agent coordination, use:

- `skills/agentic-git-workflow/SKILL.md`

This skill applies whenever repository state changes, in addition to the
task-specific implementation skills above.

