#!/usr/bin/env bash

set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
WORKERS="${WORKERS:-4}"
EXPECTED_DATE="Thu, 01 Jan 1970 00:00:00 GMT"
EXPECTED_CONTENT_TYPE="text/plain; charset=utf-8"
EXPECTED_CONTENT_LENGTH="13"
EXPECTED_BODY="Hello, World!"
TMP_DIR="$(mktemp -d)"

SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi

  rm -rf "$TMP_DIR"
}

trap cleanup EXIT INT TERM

for command in swift cargo curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 1
  fi
done

swift build -c release --product hudhud-benchmark-server
swift build -c release --product raw-nio-benchmark-server

cargo build \
  --release \
  --manifest-path Benchmarks/ActixBenchmarkServer/Cargo.toml

header_value() {
  local file="$1"
  local header="$2"

  grep -i "^$header:" "$file" \
    | head -n 1 \
    | cut -d: -f2- \
    | sed 's/^[[:space:]]*//' \
    | tr -d '\r'
}

capture() {
  local label="$1"
  local executable="$2"
  local route="$3"
  local prefix="$4"

  HUDHUD_HOST="$HOST" \
  HUDHUD_PORT="$PORT" \
  HUDHUD_THREADS="$WORKERS" \
  HUDHUD_WORKERS="$WORKERS" \
    "$executable" \
    >"$TMP_DIR/$prefix.server.log" 2>&1 &

  SERVER_PID=$!

  for _ in {1..100}; do
    if curl \
      --http1.1 \
      -fsS \
      "http://$HOST:$PORT$route" \
      >/dev/null
    then
      break
    fi

    sleep 0.1
  done

  curl \
    --http1.1 \
    -sS \
    -D "$TMP_DIR/$prefix.headers" \
    -o "$TMP_DIR/$prefix.body" \
    "http://$HOST:$PORT$route"

  cleanup_server

  printf '%-24s %s\n' "$label" "captured"
}

cleanup_server() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    sleep 0.3
  fi
}

capture \
  "Hudhud prepared" \
  ".build/release/hudhud-benchmark-server" \
  "/prepared" \
  "hudhud"

capture \
  "Raw SwiftNIO" \
  ".build/release/raw-nio-benchmark-server" \
  "/plaintext" \
  "raw-nio"

capture \
  "Actix Web" \
  "Benchmarks/ActixBenchmarkServer/target/release/hudhud-actix-benchmark" \
  "/plaintext" \
  "actix"

for prefix in hudhud raw-nio actix; do
  content_type="$(header_value "$TMP_DIR/$prefix.headers" "content-type")"
  content_length="$(header_value "$TMP_DIR/$prefix.headers" "content-length")"
  date_value="$(header_value "$TMP_DIR/$prefix.headers" "date")"
  body="$(cat "$TMP_DIR/$prefix.body")"

  if [[ "$content_type" != "$EXPECTED_CONTENT_TYPE" ]]; then
    echo "$prefix content-type mismatch: $content_type" >&2
    exit 1
  fi

  if [[ "$content_length" != "$EXPECTED_CONTENT_LENGTH" ]]; then
    echo "$prefix content-length mismatch: $content_length" >&2
    exit 1
  fi

  if [[ "$date_value" != "$EXPECTED_DATE" ]]; then
    echo "$prefix date mismatch: $date_value" >&2
    exit 1
  fi

  if [[ "$body" != "$EXPECTED_BODY" ]]; then
    echo "$prefix body mismatch: $body" >&2
    exit 1
  fi
done

echo
echo "Wire contract verified:"
echo "content-type: $EXPECTED_CONTENT_TYPE"
echo "content-length: $EXPECTED_CONTENT_LENGTH"
echo "date: $EXPECTED_DATE"
echo "body: $EXPECTED_BODY"
