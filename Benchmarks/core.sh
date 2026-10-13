#!/usr/bin/env bash

set -euo pipefail

ITERATIONS="${ITERATIONS:-1000000}"

HUDHUD_CORE_BENCHMARK=1 \
HUDHUD_CORE_ITERATIONS="$ITERATIONS" \
  swift test \
    -c release \
    --filter CoreBenchmarkTests/testCoreDispatchBenchmark
