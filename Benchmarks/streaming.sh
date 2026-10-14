#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-64}"
DURATION="${DURATION:-20s}"
WORKERS="${WORKERS:-4}"
UPLOAD_BYTES="${UPLOAD_BYTES:-65536}"

for command in wrk curl swift; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 1
  fi
done

swift build -c release --product hudhud-benchmark-server

SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

trap cleanup EXIT INT TERM

start_server() {
  HUDHUD_HOST="$HOST" \
  HUDHUD_PORT="$PORT" \
  HUDHUD_THREADS="$WORKERS" \
    .build/release/hudhud-benchmark-server \
    >/tmp/hudhud-streaming-benchmark.log 2>&1 &

  SERVER_PID=$!

  for _ in {1..100}; do
    if curl -fsS "http://$HOST:$PORT/prepared" >/dev/null; then
      return
    fi

    sleep 0.1
  done

  echo "Server did not become ready." >&2
  exit 1
}

run_case() {
  local label="$1"
  local route="$2"

  start_server

  echo
  echo "============================================================"
  echo "$label"
  echo "route=$route upload_bytes=$UPLOAD_BYTES"
  echo "workers=$WORKERS threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
  echo "============================================================"
  echo

  HUDHUD_UPLOAD_BYTES="$UPLOAD_BYTES" \
    wrk \
      -t"$THREADS" \
      -c"$CONNECTIONS" \
      -d"$DURATION" \
      --latency \
      -s Benchmarks/upload.lua \
      "http://$HOST:$PORT$route"

  cleanup
  sleep 0.5
}

run_case "Aggregated request body" "/aggregate-upload"
run_case "Streaming request body" "/stream-upload"
