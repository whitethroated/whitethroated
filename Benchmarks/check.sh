#!/usr/bin/env bash

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 1
fi

for script in Benchmarks/*.sh; do
  bash -n "$script"
done

python3 Benchmarks/test_summarize.py

echo "benchmark tooling checks passed"
