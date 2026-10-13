#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-30s}"
WORKERS="${WORKERS:-4}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required to run the comparison." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the readiness check." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required to build the Actix Web control." >&2
  exit 1
fi

swift build -c release --product hudhud-benchmark-server
cargo build \
  --release \
  --manifest-path Benchmarks/ActixBenchmarkServer/Cargo.toml

SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

trap cleanup EXIT INT TERM

wait_until_ready() {
  local route="$1"

  for _ in {1..100}; do
    if curl -fsS "http://$HOST:$PORT$route" >/dev/null; then
      return
    fi

    sleep 0.1
  done

  echo "Server did not become ready." >&2
  exit 1
}

run_case() {
  local label="$1"
  local executable="$2"
  local route="$3"
  local log_file="$4"
  shift 4

  env \
    HUDHUD_HOST="$HOST" \
    HUDHUD_PORT="$PORT" \
    HUDHUD_THREADS="$WORKERS" \
    HUDHUD_WORKERS="$WORKERS" \
    "$@" \
    "$executable" \
    >"$log_file" 2>&1 &

  SERVER_PID=$!

  wait_until_ready "$route"

  echo
  echo "============================================================"
  echo "$label"
  echo "route=$route"
  echo "workers=$WORKERS threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
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
  "/tmp/hudhud-actix-compare-hudhud-prepared.log"

run_case \
  "Hudhud synchronous handler" \
  ".build/release/hudhud-benchmark-server" \
  "/plaintext" \
  "/tmp/hudhud-actix-compare-hudhud-sync.log"

run_case \
  "Actix Web 4.16.0 synchronous payload" \
  "Benchmarks/ActixBenchmarkServer/target/release/hudhud-actix-benchmark" \
  "/plaintext" \
  "/tmp/hudhud-actix-compare-actix.log"
