# CircleCI validation

CircleCI is the automatic CI provider for WhiteThroated while GitHub-hosted
Actions are unavailable because of account usage or billing limits.

The canonical validation contract remains the same. CircleCI mirrors the
release-mode tests, diagnostic smoke tests, and release product builds from the
GitHub Actions workflow.

## Configuration

The repository configuration lives at:

```text
.circleci/config.yml
```

The job uses:

- Swift 6.4.0 on the official `swift:6.4.0-noble` image;
- PostgreSQL 16 as a secondary service container;
- `medium+` Docker resources;
- `libpq-dev`, `pkg-config`, `postgresql-client`, and `zlib1g-dev`;
- SwiftPM dependency caching keyed by `Package.resolved`.

PostgreSQL is reachable from the primary container at `127.0.0.1:5432`.

## CircleCI project setup

Use the CircleCI GitHub App integration.

In CircleCI:

1. Connect the `whitethroated/whitethroated` repository.
2. Use `.circleci/config.yml` as the pipeline configuration.
3. Add one GitHub App trigger using:
   `PR opened or pushed to, default branch and tag pushes`.
4. Do not add overlapping push/PR triggers, because duplicate triggers consume
   credits without adding validation value.

The workflow itself runs only when:

- the pipeline event is a pull request; or
- the branch is `main`.

Tag pipelines created by the GitHub App trigger therefore do not execute the CI
workflow.

## Validation parity

The CircleCI `validate` job runs:

```text
swift package resolve
swift test -c release
swift test -c release --filter CoreBenchmarkTests
swift test -c release --filter RuntimeServerPipelineTests/testHTTP1PipelineBenchmark
swift build -c release --product whitethroated-example
swift build -c release --product whitethroated-migrate
swift build -c release --product whitethroated-benchmark-server
swift build -c release --product raw-nio-benchmark-server
swift build -c release --product whitethroated-runtime-benchmark-server
swift build -c release --product whitethroated-benchmark-client
swift build -c release --product whitethroated-websocket-benchmark-server
swift build -c release --product whitethroated-websocket-benchmark-client
swift build -c release --product whitethroated-benchmark-merge
swift build -c release --product whitethroated-benchmark-campaign
```

The diagnostic benchmark steps are smoke validation only. CircleCI-hosted
timing is not publishable performance evidence.

## Merge gate while GitHub Actions is blocked

A pull request may satisfy the repository CI gate with CircleCI when all of the
following are true:

- CircleCI validated the current PR head SHA;
- the `validate` job completed successfully;
- the PR is based on a sufficiently fresh `main`;
- the final diff is focused and reviewed;
- all task-specific correctness and benchmark requirements are satisfied.

A GitHub Actions failure caused only by account usage/billing exhaustion is an
infrastructure failure, not a code failure. It must not be treated as a green
check, but it also does not invalidate a successful equivalent CircleCI run.

Do not merge if CircleCI is pending, failed, stale, or has not run for the
current head.

## GitHub Actions

`.github/workflows/ci.yml` is retained as the parity workflow, but automatic
push and pull-request triggers are disabled while GitHub-hosted capacity is
blocked.

It can be started manually with `workflow_dispatch` after GitHub-hosted
capacity becomes available.

When GitHub Actions automatic execution is restored, re-enable the `push` and
`pull_request` triggers in a dedicated CI change and verify that the two
providers still execute equivalent validation.

## Credit discipline

CircleCI is also usage-limited. Keep CI runs intentional:

- use short-lived pull-request branches;
- avoid meaningless commits that only retrigger CI;
- do not configure duplicate GitHub App triggers;
- rerun failed jobs only when the failure is transient or a fix was applied;
- keep the SwiftPM dependency cache enabled;
- review CircleCI resource usage before increasing `resource_class`.

`medium+` is the initial balance for Swift release compilation. If observed
memory use is comfortably below the limit, test `medium` in a dedicated CI
change before reducing it. If builds are memory-constrained, increase the
resource class only with evidence.
