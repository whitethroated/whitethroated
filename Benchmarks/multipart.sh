#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-32}"
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
HUDHUD_UPLOAD_BENCHMARKS=1 \
HUDHUD_MULTIPART_BENCHMARKS=1 \
  .build/release/hudhud-benchmark-server \
  >/tmp/hudhud-multipart-benchmark.log 2>&1 &

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
  local bytes="$3"

  echo
  echo "============================================================"
  echo "$label"
  echo "route=$route multipart_file_bytes=$bytes"
  echo "workers=$WORKERS threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
  echo "============================================================"
  echo

  HUDHUD_MULTIPART_FILE_BYTES="$bytes" \
  wrk \
    -t"$THREADS" \
    -c"$CONNECTIONS" \
    -d"$DURATION" \
    --latency \
    -s Benchmarks/multipart.lua \
    "http://$HOST:$PORT$route"
}

for bytes in 1024 65536 1048576; do
  run_case \
    "Raw streaming control with multipart wire bytes" \
    "/upload-stream" \
    "$bytes"

  run_case \
    "Streaming multipart parser" \
    "/upload-multipart" \
    "$bytes"
done
