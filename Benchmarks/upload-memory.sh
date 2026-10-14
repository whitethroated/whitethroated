#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-64}"
DURATION="${DURATION:-20s}"
WORKERS="${WORKERS:-4}"
BYTES="${BYTES:-1048576}"

if (( BYTES > 1048576 )); then
  echo "BYTES must be <= 1048576 for the aggregated benchmark route." >&2
  exit 1
fi

for command in swift wrk curl ps; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 1
  fi
done

swift build -c release --product hudhud-benchmark-server

SERVER_PID=""
MONITOR_PID=""

cleanup() {
  if [[ -n "$MONITOR_PID" ]]; then
    kill "$MONITOR_PID" >/dev/null 2>&1 || true
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
  fi

  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

trap cleanup EXIT INT TERM

rss_kb() {
  ps -o rss= -p "$1" \
    | tr -d '[:space:]'
}

wait_until_ready() {
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
  local peak_file

  peak_file="$(mktemp)"

  HUDHUD_HOST="$HOST" \
  HUDHUD_PORT="$PORT" \
  HUDHUD_THREADS="$WORKERS" \
  HUDHUD_UPLOAD_BENCHMARKS=1 \
    .build/release/hudhud-benchmark-server \
    >/tmp/hudhud-upload-memory.log 2>&1 &

  SERVER_PID=$!
  wait_until_ready

  local baseline
  baseline="$(rss_kb "$SERVER_PID")"

  if [[ ! "$baseline" =~ ^[0-9]+$ ]]; then
    echo "Unable to read numeric RSS for server process." >&2
    exit 1
  fi

  (
    peak="$baseline"

    while kill -0 "$SERVER_PID" >/dev/null 2>&1; do
      current="$(rss_kb "$SERVER_PID" || true)"

      if [[ "$current" =~ ^[0-9]+$ ]] && (( current > peak )); then
        peak="$current"
      fi

      sleep 0.05
    done

    echo "$peak" >"$peak_file"
  ) &

  MONITOR_PID=$!

  echo
  echo "============================================================"
  echo "$label"
  echo "route=$route upload_bytes=$BYTES"
  echo "workers=$WORKERS threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
  echo "============================================================"
  echo

  HUDHUD_UPLOAD_BYTES="$BYTES" \
  wrk \
    -t"$THREADS" \
    -c"$CONNECTIONS" \
    -d"$DURATION" \
    --latency \
    -s Benchmarks/upload.lua \
    "http://$HOST:$PORT$route"

  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""

  wait "$MONITOR_PID" 2>/dev/null || true
  MONITOR_PID=""

  local peak
  peak="$(cat "$peak_file")"
  rm -f "$peak_file"

  local growth
  growth=$(( peak - baseline ))

  echo
  echo "baseline_rss_kb=$baseline"
  echo "peak_rss_kb=$peak"
  echo "rss_growth_kb=$growth"
}

run_case \
  "Aggregated request body memory" \
  "/upload-aggregated"

run_case \
  "Streaming request body memory" \
  "/upload-stream"
