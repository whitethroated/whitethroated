#!/usr/bin/env bash

set -euo pipefail

ITERATIONS="${ITERATIONS:-100000}"

HUDHUD_TRANSPORT_BENCHMARK=1 \
HUDHUD_TRANSPORT_ITERATIONS="$ITERATIONS" \
  swift test \
    -c release \
    --filter CoreBenchmarkTests/testTransportWriterBenchmark
