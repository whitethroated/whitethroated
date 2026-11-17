## Summary

## Tests

- [ ] Targeted tests pass
- [ ] `swift test -c release` passes
- [ ] Affected products build in release mode

## Performance (if the hot path changes)

- [ ] Before/after release-mode measurements on the same machine
- [ ] Identical requests, concurrency, and warm-up (see BENCHMARKS.md)
- [ ] requests/s plus p50/p90/p99/max reported; no benchmark-only shortcut

## Hygiene

- [ ] Commit identity is the noreply identity
- [ ] No credentials or personal emails in the diff
