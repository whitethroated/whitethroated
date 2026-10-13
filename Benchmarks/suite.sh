#!/usr/bin/env bash

set -euo pipefail

MODE="${MODE:-raw-nio}"
SAMPLES="${SAMPLES:-5}"
THREADS="${THREADS:-4}"
CONNECTIONS="${CONNECTIONS:-128}"
DURATION="${DURATION:-30s}"
WORKERS="${WORKERS:-4}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${OUTPUT_DIR:-benchmark-results/${STAMP}-${MODE}}"

mkdir -p "$OUTPUT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to summarize benchmark results." >&2
  exit 1
fi

case "$MODE" in
  raw-nio)
    RUNNER="./Benchmarks/compare.sh"
    ;;
  actix)
    RUNNER="./Benchmarks/compare-actix.sh"
    ;;
  *)
    echo "MODE must be raw-nio or actix." >&2
    exit 1
    ;;
esac

{
  echo "timestamp_utc=$STAMP"
  echo "mode=$MODE"
  echo "samples=$SAMPLES"
  echo "threads=$THREADS"
  echo "connections=$CONNECTIONS"
  echo "duration=$DURATION"
  echo "workers=$WORKERS"
  echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo
  echo "== uname =="
  uname -a || true
  echo
  echo "== CPU =="
  if command -v lscpu >/dev/null 2>&1; then
    lscpu
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -a 2>/dev/null | grep -E 'machdep.cpu|hw.ncpu' || true
  fi
  echo
  echo "== Swift =="
  swift --version || true
  echo
  echo "== wrk =="
  wrk --version || true

  if [[ "$MODE" == "actix" ]]; then
    echo
    echo "== Rust =="
    rustc --version || true
    cargo --version || true
  fi
} >"$OUTPUT_DIR/environment.txt"

for sample in $(seq 1 "$SAMPLES"); do
  echo
  echo "Running sample $sample/$SAMPLES"

  THREADS="$THREADS" \
  CONNECTIONS="$CONNECTIONS" \
  DURATION="$DURATION" \
  WORKERS="$WORKERS" \
    "$RUNNER" \
    | tee "$OUTPUT_DIR/sample-${sample}.txt"
done

echo
python3 ./Benchmarks/summarize.py "$OUTPUT_DIR"

echo
echo "Benchmark records:"
echo "$OUTPUT_DIR"
echo "Summary:"
echo "$OUTPUT_DIR/summary.md"
