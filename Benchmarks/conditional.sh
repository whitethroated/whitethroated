#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-20s}"
WORKERS="${WORKERS:-4}"

for command in swift wrk curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 1
  fi
done

swift build -c release --product hudhud-benchmark-server

HUDHUD_HOST="$HOST" \
HUDHUD_PORT="$PORT" \
HUDHUD_THREADS="$WORKERS" \
  .build/release/hudhud-benchmark-server \
  >/tmp/hudhud-conditional-benchmark.log 2>&1 &

SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

for _ in {1..100}; do
  if curl -fsS "http://$HOST:$PORT/prepared" >/dev/null; then
    break
  fi
  sleep 0.1
done

run_case() {
  local label="$1"
  local route="$2"
  local header="${3:-}"

  echo
  echo "============================================================"
  echo "$label"
  echo "route=$route"
  echo "workers=$WORKERS threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
  echo "============================================================"
  echo

  if [[ -n "$header" ]]; then
    wrk \
      -t"$THREADS" \
      -c"$CONNECTIONS" \
      -d"$DURATION" \
      --latency \
      -H "$header" \
      "http://$HOST:$PORT$route"
  else
    wrk \
      -t"$THREADS" \
      -c"$CONNECTIONS" \
      -d"$DURATION" \
      --latency \
      "http://$HOST:$PORT$route"
  fi
}

run_case "Prepared baseline" "/prepared"
run_case "Conditional prepared 200" "/conditional-prepared"
run_case \
  "Conditional prepared 304" \
  "/conditional-prepared" \
  'If-None-Match: "benchmark-v1"'
