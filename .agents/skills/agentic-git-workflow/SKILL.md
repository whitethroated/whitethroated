# Skill: agentic Git workflow

Use this skill whenever a task creates or changes a branch, commit, pull request,
review, CI run, merge, or other repository state.

This skill governs repository integration. Combine it with the task-specific
skills that govern the code or documentation being changed.

## Principle

Treat `main` as the integration source of truth.

Agent speed is not a reason to weaken integration discipline. Agents may produce
changes quickly, but correctness comes from small scope, independent verification,
fresh integration state, and reproducible evidence.

Use short-lived task branches, focused commits, pull requests, CI, and explicit
merge gates. Do not treat an agent's own statement that "tests pass" as evidence.

## Default workflow

For repository changes, use this sequence:

1. Inspect current `main`, relevant open pull requests, and repository instructions.
2. Define one task with explicit acceptance criteria.
3. Create a fresh, short-lived branch from the current `main`.
4. Implement only that task.
5. Run the applicable correctness, release-build, and benchmark validation.
6. Inspect the final diff for scope drift and accidental generated changes.
7. Create focused commits with meaningful messages.
8. Open a pull request against `main`.
9. Verify CI and review state independently from the implementation agent's claims.
10. Revalidate integration freshness if `main` moved.
11. Merge only when every applicable gate is satisfied and the task authorizes merge.
12. Delete or retire the task branch after merge.

Do not use long-lived `develop`, `integration`, or agent-specific branches as a
substitute for keeping `main` continuously integratable.

## Preflight

Before editing:

- read the root `AGENTS.md`;
- load the task-specific skills that apply;
- inspect the current `main` head;
- inspect open pull requests that may touch the same subsystem or files;
- identify tests, builds, benchmarks, docs, and compatibility gates required by
  the proposed change;
- decide whether the work is independent or intentionally stacked on another PR.

If another active PR overlaps materially with the same hot path or files, avoid
parallel conflicting edits unless the work is intentionally coordinated.

Do not start from a stale local or remote branch merely because it already exists.

## Branch policy

Create branches from the latest `main` unless the task is intentionally a
stacked change.

Name branches by intent, not by agent identity.

Preferred prefixes:

- `feat/`
- `fix/`
- `perf/`
- `refactor/`
- `test/`
- `bench/`
- `docs/`
- `ci/`
- `chore/`

Examples:

- `perf/router-static-cache`
- `fix/http1-header-validation`
- `feat/websocket-compression`
- `bench/linux-arm64-baseline`
- `docs/runtime-architecture`

Avoid names such as:

- `agent-1`
- `codex-work`
- `claude-task`
- `chatgpt-fixes`
- `misc-changes`

A branch should represent one reviewable objective.

Keep branches short-lived. If a branch accumulates multiple unrelated objectives,
split the work before opening or merging the PR.

## Parallel-agent discipline

Multiple agents may work concurrently, but integration must remain serialized
through `main`.

Each agent should:

- own a narrow task;
- avoid editing unrelated files;
- inspect open PRs before starting;
- prefer independent file or subsystem boundaries when practical;
- communicate dependencies through PR relationships or issue context rather than
  hidden assumptions;
- never assume another agent's unmerged code exists on `main`.

When two tasks depend on each other, either:

1. finish and merge the prerequisite first, then branch the dependent task from
   updated `main`; or
2. use an explicit stacked-PR relationship and state the dependency in the PR.

Do not silently build a dependent change on another unmerged branch and then open
it as if it were independent.

## Commit discipline

Keep commits conceptually atomic.

A good commit should answer one question: what coherent repository state changed,
and why?

Use concise English commit messages. Conventional prefixes are encouraged when
they fit the repository history:

- `feat:`
- `fix:`
- `perf:`
- `refactor:`
- `test:`
- `bench:`
- `docs:`
- `ci:`
- `chore:`

Examples:

- `perf(router): precompute static route lookup keys`
- `test(http1): cover conflicting content-length headers`
- `bench(runtime): add pooled latency export`

Do not use meaningless messages such as `update`, `changes`, `fix stuff`, or
`agent work`.

Do not mix:

- formatting churn with hot-path changes;
- unrelated refactors with feature work;
- benchmark-control changes with production optimizations when that would make
  attribution ambiguous;
- test weakening with implementation changes;
- dependency upgrades with unrelated functionality.

WIP commits are acceptable while exploring, but clean the final history when they
do not preserve useful reasoning.

## Pull request policy

Repository changes should normally enter `main` through a pull request, even when
the hosting platform technically permits direct pushes.

A PR should contain:

- the problem or objective;
- the implementation summary;
- correctness evidence;
- tests and release builds run;
- benchmark evidence when applicable;
- behavior, API, architecture, or dependency impact;
- known tradeoffs or unresolved risks;
- explicit merge gate.

Keep PRs small enough that a reviewer or another agent can understand the entire
change without reconstructing several unrelated tasks.

Draft PRs are appropriate for intentionally incomplete work. Do not mark a PR
ready merely because code generation has stopped.

## Independent verification

Never use the implementation agent's prose as the merge gate.

Verify repository state directly:

- inspect the changed filenames and diff;
- verify the PR head SHA;
- inspect CI status for that SHA;
- inspect failed job logs rather than guessing;
- inspect unresolved review threads when review is required;
- confirm the PR is mergeable;
- confirm required documentation and tests are present.

If a result cannot be verified, report it as unverified rather than assuming it
passed.

## CI policy

CI proves deterministic correctness and buildability on the configured runner.

For this repository, the release test suite and release product builds defined by
the canonical instructions and CI are the minimum general-purpose integration
signal.

When CI fails:

1. identify whether the failure is deterministic code failure, test failure,
   environment failure, or infrastructure flake;
2. inspect the failed step or logs;
3. fix deterministic failures in code;
4. rerun only when there is evidence the failure was transient or after a fix;
5. do not repeatedly rerun a deterministic failure hoping for green.

A green CI run on an old PR head is not evidence for a newer head.

## Performance-sensitive changes

Any request-time, transport, routing, allocation, serialization, middleware,
streaming, concurrency, or memory optimization must also use
`.agents/skills/benchmark-validation/SKILL.md`.

For performance work:

- correctness comes first;
- use release builds;
- compare equivalent semantics;
- measure a relevant baseline and candidate on the same environment;
- use multiple measured rounds;
- capture throughput and latency distributions, not only peak RPS;
- include p50, p90, and p99 at minimum when the harness supports them;
- capture RSS or allocation evidence when memory is part of the claim;
- use raw SwiftNIO controls when the framework/runtime tax is relevant;
- classify results inside ordinary variance as neutral;
- reject benchmark-only shortcuts.

GitHub-hosted CI benchmark smoke tests validate that the harness executes. They
are not stable-hardware performance evidence and must not be used to publish
latency or throughput wins.

A throughput improvement does not automatically pass if tail latency, memory, or
important concurrency levels regress materially.

## Integration freshness

CI results are valid for the exact code state they tested.

Before merge, verify whether `main` changed after the PR branch point or after
the last meaningful validation.

If changes on `main` can affect the PR:

1. update or rebase the task branch onto current `main`;
2. resolve conflicts without dropping correctness coverage;
3. rerun the applicable CI and validation;
4. inspect the resulting diff again.

If a merge queue is available and configured, prefer it for serialized,
post-update validation. Otherwise enforce the same discipline manually.

Do not merge based on a green check that only proved compatibility with a stale
integration base.

## Merge policy

Merge only when all applicable gates are satisfied.

Minimum gates:

- the task scope is complete;
- the diff is focused;
- targeted tests pass;
- the release test suite passes;
- relevant release products build;
- CI for the current head is green;
- required review threads are resolved;
- public behavior has regression coverage;
- performance-sensitive changes have valid benchmark evidence;
- required docs are updated;
- no repository constraints were violated;
- the integration base is fresh enough to trust the validation.

If the user or task explicitly authorizes end-to-end completion, the agent may
merge after these gates pass.

If merge was not authorized, stop at a merge-ready PR and report the exact state.

Never bypass a failing or pending gate solely to finish the task faster.

When performing a merge through an API, use the expected PR head SHA when the
tool supports it so a moved head cannot be merged accidentally.

Use the repository's established merge method. Do not preserve noisy WIP history
merely because it was agent-generated.

## Direct-to-main changes

Do not push implementation changes directly to `main` by default, even if
branch protection is absent.

A direct-to-main change requires explicit user intent and must still satisfy all
applicable correctness and performance gates before the write.

An emergency does not justify silently skipping validation. If validation must be
reduced, state exactly what could and could not be verified.

## Review discipline

Review the code that exists, not the PR description.

Check for:

- accidental API or response-semantic changes;
- hidden allocations or concurrency changes on hot paths;
- missing regression coverage;
- weakened assertions;
- benchmark-control drift;
- unrelated generated files;
- dependency changes;
- non-Swift implementation source;
- stale documentation;
- security or HTTP-correctness regressions;
- code that only makes a public benchmark easier.

For risky changes, prefer a second independent review pass after CI is green.

## Recovery and rollback

If a merged change causes a regression:

- preserve evidence of the regression;
- prefer a narrow revert when root cause is not yet proven;
- fix forward only when the corrective change is understood and independently
  validated;
- do not stack speculative optimizations on top of an unverified regression.

A rollback is a correctness action, not a failure of the workflow.

## Repository-language rule

Generated repository artifacts must use English, including:

- branch names;
- commit messages;
- PR titles and descriptions;
- issue text;
- code identifiers and comments;
- generated documentation and benchmark reports.

Conversation language does not change the repository artifact language.

## Forbidden patterns

Do not:

- use long-lived integration branches by default;
- create one branch for several unrelated tasks;
- identify branches by agent name instead of intent;
- push to `main` merely because it is technically allowed;
- merge with failing, pending, stale, or unverified CI;
- treat one benchmark run as proof;
- hide regressions by changing benchmark semantics;
- weaken tests to make an optimization pass;
- rewrite unrelated files;
- repeatedly rerun deterministic CI failures;
- claim a PR is safe without inspecting its actual head and checks;
- merge a PR whose head changed after the state you reviewed.

## Definition of done

For a Git-backed task, done means every applicable item below is true:

- the task started from an intentional and documented base;
- the branch name describes the change;
- the branch contains one coherent objective;
- commits are focused and meaningful;
- implementation is complete;
- targeted tests pass;
- release tests and required products pass;
- performance evidence exists when the hot path changed;
- docs are updated when behavior or invariants changed;
- the final diff was inspected;
- the PR describes evidence and tradeoffs accurately;
- CI is green for the current PR head;
- integration freshness was checked;
- merge happened only when authorized and gated, otherwise the PR is explicitly
  reported as merge-ready.

The repository, tests, CI, benchmark evidence, and current Git state are the
source of truth. Agent confidence is not.
