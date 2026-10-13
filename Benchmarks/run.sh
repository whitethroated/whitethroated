#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-30s}"
ROUTE="${ROUTE:-/plaintext}"

if ! command -v wrk >/dev/null 2>&1; then
  echo "wrk is required to run the network benchmark." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the readiness check." >&2
  exit 1
fi

swift build -c release --product hudhud-benchmark-server

HUDHUD_HOST="$HOST" HUDHUD_PORT="$PORT"   .build/release/hudhud-benchmark-server   >/tmp/hudhud-benchmark-server.log 2>&1 &

SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

for _ in {1..50}; do
  if curl -fsS "http://$HOST:$PORT/plaintext" >/dev/null; then
    break
  fi

  sleep 0.1
done

curl -fsS "http://$HOST:$PORT/plaintext" >/dev/null

echo "Hudhud benchmark"
echo "route=$ROUTE threads=$THREADS connections=$CONNECTIONS duration=$DURATION"
echo

wrk   -t"$THREADS"   -c"$CONNECTIONS"   -d"$DURATION"   --latency   "http://$HOST:$PORT$ROUTE"
