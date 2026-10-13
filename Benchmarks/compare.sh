#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-30s}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required to run the comparison." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the readiness check." >&2
  exit 1
fi

swift build -c release --product hudhud-benchmark-server
swift build -c release --product raw-nio-benchmark-server

SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

trap cleanup EXIT INT TERM

run_case() {
  local label="$1"
  local executable="$2"
  local route="$3"
  local readiness_route="$4"
  local log_file="$5"

  HUDHUD_HOST="$HOST" HUDHUD_PORT="$PORT" \
    "$executable" >"$log_file" 2>&1 &

  SERVER_PID=$!

  for _ in {1..50}; do
    if curl -fsS "http://$HOST:$PORT$readiness_route" >/dev/null; then
      break
    fi

    sleep 0.1
  done

  curl -fsS "http://$HOST:$PORT$readiness_route" >/dev/null

  echo
  echo "============================================================"
  echo "$label"
  echo "threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
  echo "============================================================"
  echo

  wrk \
    -t"$THREADS" \
    -c"$CONNECTIONS" \
    -d"$DURATION" \
    --latency \
    "http://$HOST:$PORT$route"

  cleanup
  sleep 0.5
}

run_case \
  "Hudhud prepared response" \
  ".build/release/hudhud-benchmark-server" \
  "/prepared" \
  "/prepared" \
  "/tmp/hudhud-compare.log"

run_case \
  "Raw SwiftNIO control" \
  ".build/release/raw-nio-benchmark-server" \
  "/plaintext" \
  "/plaintext" \
  "/tmp/raw-nio-compare.log"
