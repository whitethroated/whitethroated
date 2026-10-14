#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-15s}"
WORKERS="${WORKERS:-4}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required to run the router benchmark." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the readiness check." >&2
  exit 1
fi

swift build -c release --product hudhud-benchmark-server

HUDHUD_HOST="$HOST" \
HUDHUD_PORT="$PORT" \
HUDHUD_THREADS="$WORKERS" \
HUDHUD_ROUTER_BENCHMARKS=1 \
  .build/release/hudhud-benchmark-server \
  >/tmp/hudhud-router-benchmark.log 2>&1 &

SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

for _ in {1..50}; do
  if curl -fsS "http://$HOST:$PORT/prepared" >/dev/null; then
    break
  fi

  sleep 0.1
done

curl -fsS "http://$HOST:$PORT/prepared" >/dev/null

run_case() {
  local label="$1"
  local route="$2"
  local method="${3:-GET}"

  curl \
    -fsS \
    -X "$method" \
    "http://$HOST:$PORT$route" \
    >/dev/null

  echo
  echo "============================================================"
  echo "$label"
  echo "route=$route method=$method"
  echo "workers=$WORKERS threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
  echo "============================================================"
  echo

  HUDHUD_ROUTER_METHOD="$method" \
  wrk \
    -t"$THREADS" \
    -c"$CONNECTIONS" \
    -d"$DURATION" \
    --latency \
    -s Benchmarks/router-method.lua \
    "http://$HOST:$PORT$route"
}

run_case "Prepared exact-static baseline" "/prepared"
run_case "Prepared trie-fallback control" "/prepared/"

run_case "Exact static depth 1" "/depth/s1"
run_case "Trie static depth 1" "/depth/s1/"
run_case "Exact static depth 4" "/depth/s1/s2/s3/s4"
run_case "Trie static depth 4" "/depth/s1/s2/s3/s4/"
run_case "Exact static depth 8" "/depth/s1/s2/s3/s4/s5/s6/s7/s8"
run_case "Trie static depth 8" "/depth/s1/s2/s3/s4/s5/s6/s7/s8/"
run_case "Exact static depth 16" "/depth/s1/s2/s3/s4/s5/s6/s7/s8/s9/s10/s11/s12/s13/s14/s15/s16"
run_case "Trie static depth 16" "/depth/s1/s2/s3/s4/s5/s6/s7/s8/s9/s10/s11/s12/s13/s14/s15/s16/"

run_case "Exact fan-out 16" "/fanout/16/r15"
run_case "Trie fan-out 16" "/fanout/16/r15/"
run_case "Exact fan-out 256" "/fanout/256/r255"
run_case "Trie fan-out 256" "/fanout/256/r255/"
run_case "Exact fan-out 4096" "/fanout/4096/r4095"
run_case "Trie fan-out 4096" "/fanout/4096/r4095/"

run_case \
  "Dynamic route with populated exact table" \
  "/dynamic-control/v1" \
  "GET"

run_case \
  "Dynamic route with empty exact table" \
  "/dynamic-control/v1" \
  "PUT"

run_case "Dynamic params 1" "/dynamic/a/v1"
run_case "Dynamic params 2" "/dynamic/a/v1/b/v2"
run_case "Dynamic params 4" "/dynamic/a/v1/b/v2/c/v3/d/v4"
