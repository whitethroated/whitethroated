#!/usr/bin/env bash

set -euo pipefail

ITERATIONS="${ITERATIONS:-2000000}"

HUDHUD_ROUTER_CORE_BENCHMARK=1 \
HUDHUD_ROUTER_CORE_ITERATIONS="$ITERATIONS" \
  swift test \
    -c release \
    --filter CoreBenchmarkTests/testRouterLookupBenchmark
