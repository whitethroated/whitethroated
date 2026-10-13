#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION_SECONDS="${DURATION_SECONDS:-20}"
DURATION="${DURATION:-${DURATION_SECONDS}s}"
WORKERS="${WORKERS:-4}"
ROUTE="${ROUTE:-/plaintext}"
PROFILE_MODE="${PROFILE_MODE:-stat}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${OUTPUT_DIR:-benchmark-results/${STAMP}-profile}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This profiler currently supports Linux perf only." >&2
  exit 1
fi

for command in perf wrk curl swift; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 1
  fi
done

case "$PROFILE_MODE" in
  stat|record)
    ;;
  *)
    echo "PROFILE_MODE must be stat or record." >&2
    exit 1
    ;;
esac

mkdir -p "$OUTPUT_DIR"

swift build -c release --product hudhud-benchmark-server

HUDHUD_HOST="$HOST" \
HUDHUD_PORT="$PORT" \
HUDHUD_THREADS="$WORKERS" \
  .build/release/hudhud-benchmark-server \
  >"$OUTPUT_DIR/server.log" 2>&1 &

SERVER_PID=$!
PROFILER_PID=""

cleanup() {
  if [[ -n "$PROFILER_PID" ]]; then
    kill "$PROFILER_PID" >/dev/null 2>&1 || true
    wait "$PROFILER_PID" 2>/dev/null || true
  fi

  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

for _ in {1..100}; do
  if curl -fsS "http://$HOST:$PORT$ROUTE" >/dev/null; then
    break
  fi

  sleep 0.1
done

curl -fsS "http://$HOST:$PORT$ROUTE" >/dev/null

{
  echo "timestamp_utc=$STAMP"
  echo "route=$ROUTE"
  echo "profile_mode=$PROFILE_MODE"
  echo "workers=$WORKERS"
  echo "threads=$THREADS"
  echo "connections=$CONNECTIONS"
  echo "duration=$DURATION"
  echo "duration_seconds=$DURATION_SECONDS"
  echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo
  uname -a
  echo
  swift --version
} >"$OUTPUT_DIR/environment.txt"

if [[ "$PROFILE_MODE" == "stat" ]]; then
  perf stat \
    -x, \
    -e task-clock \
    -e cycles \
    -e instructions \
    -e branches \
    -e branch-misses \
    -e cache-references \
    -e cache-misses \
    -e context-switches \
    -e cpu-migrations \
    -e page-faults \
    -p "$SERVER_PID" \
    -o "$OUTPUT_DIR/perf-stat.csv" \
    -- sleep "$DURATION_SECONDS" &

  PROFILER_PID=$!
else
  perf record \
    -F 999 \
    -g \
    -p "$SERVER_PID" \
    -o "$OUTPUT_DIR/perf.data" \
    -- sleep "$DURATION_SECONDS" &

  PROFILER_PID=$!
fi

wrk \
  -t"$THREADS" \
  -c"$CONNECTIONS" \
  -d"$DURATION" \
  --latency \
  "http://$HOST:$PORT$ROUTE" \
  | tee "$OUTPUT_DIR/wrk.txt"

wait "$PROFILER_PID"
PROFILER_PID=""

if [[ "$PROFILE_MODE" == "record" ]]; then
  perf report \
    --stdio \
    --no-children \
    -i "$OUTPUT_DIR/perf.data" \
    >"$OUTPUT_DIR/perf-report.txt"

  grep -Ei \
    'swift.*(retain|release)|swift_(retain|release)' \
    "$OUTPUT_DIR/perf-report.txt" \
    >"$OUTPUT_DIR/arc-symbols.txt" \
    || true
fi

echo
echo "Profile written to:"
echo "$OUTPUT_DIR"
