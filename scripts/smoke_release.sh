#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORKER="$ROOT/dist/Tiro.app/Contents/Resources/worker/tiro-worker"
TEMP_ROOT="$(mktemp -d)"
PORT="$("$ROOT/.venv/bin/python" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
TOKEN="tiro-release-smoke"
PID=""

cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ ! -x "$WORKER" ]]; then
    print -u2 "release worker not found; run ./scripts/build_native_app.sh release first"
    exit 1
fi

mkdir -p "$TEMP_ROOT/data" "$TEMP_ROOT/models"
env \
    TIRO_DATA_DIR="$TEMP_ROOT/data" \
    TIRO_MODEL_DIR="$TEMP_ROOT/models" \
    TIRO_WORKER_TOKEN="$TOKEN" \
    TIRO_PORT="$PORT" \
    "$WORKER" >"$TEMP_ROOT/worker.log" 2>&1 &
PID=$!

for _ in {1..80}; do
    if curl -fsS "http://127.0.0.1:$PORT/api/status" >"$TEMP_ROOT/status.json" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
        cat "$TEMP_ROOT/worker.log" >&2
        exit 1
    fi
    sleep 0.25
done

"$ROOT/.venv/bin/python" -c \
    'import json, sys; status=json.load(open(sys.argv[1])); assert status["api_version"] == 6 and status["ready"]' \
    "$TEMP_ROOT/status.json"

curl -fsS -X POST \
    -H "X-Tiro-Worker-Token: $TOKEN" \
    "http://127.0.0.1:$PORT/api/shutdown" >/dev/null
wait "$PID"
PID=""

print "Release worker smoke check passed"
