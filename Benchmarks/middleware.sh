#!/usr/bin/env bash

set -euo pipefail

THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-15s}"
ROUTE="${ROUTE:-/plaintext}"

run_case() {
  local label="$1"
  local fast_layers="$2"
  local async_layers="$3"

  echo
  echo "============================================================"
  echo "$label"
  echo "route=$ROUTE"
  echo "fast_layers=$fast_layers async_layers=$async_layers"
  echo "============================================================"
  echo

  FAST_MIDDLEWARE_LAYERS="$fast_layers" \
  ASYNC_MIDDLEWARE_LAYERS="$async_layers" \
  THREADS="$THREADS" \
  CONNECTIONS="$CONNECTIONS" \
  DURATION="$DURATION" \
  ROUTE="$ROUTE" \
    ./Benchmarks/run.sh
}

run_case "No middleware" 0 0

for layers in 1 4 8; do
  run_case "Fast middleware x$layers" "$layers" 0
done

for layers in 1 4 8; do
  run_case "Async middleware x$layers" 0 "$layers"
done
