#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Tiro.app"
SIGNING_LEVEL="ad-hoc"
EXPECTED_VERSION=""
EXPECTED_BUILD=""

usage() {
    cat <<'USAGE'
usage: smoke_release.sh [options]

Options:
  --app PATH                 App bundle to test (default: dist/Tiro.app)
  --developer-id             Require Developer ID and hardened runtime
  --notarized                Also require a staple and Gatekeeper acceptance
  --expected-version VERSION Assert CFBundleShortVersionString
  --expected-build NUMBER    Assert CFBundleVersion
  -h, --help                 Show this help
USAGE
}

fail() {
    print -u2 "error: $*"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --app|--expected-version|--expected-build)
            (( $# >= 2 )) || fail "$1 requires a value"
            option="$1"
            value="$2"
            shift 2
            case "$option" in
                --app) APP="${value:A}" ;;
                --expected-version) EXPECTED_VERSION="$value" ;;
                --expected-build) EXPECTED_BUILD="$value" ;;
            esac
            ;;
        --developer-id)
            SIGNING_LEVEL="developer-id"
            shift
            ;;
        --notarized)
            SIGNING_LEVEL="notarized"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "unknown argument: $1"
            usage >&2
            exit 64
            ;;
    esac
done

[[ -d "$APP" ]] || fail "app bundle not found: $APP"
INFO="$APP/Contents/Info.plist"
WORKER="$APP/Contents/Resources/worker/tiro-worker"
[[ -f "$INFO" ]] || fail "Info.plist not found in app bundle"
[[ -x "$WORKER" ]] || fail "release worker not found; build a self-contained release first"
plutil -lint "$INFO" >/dev/null

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
[[ -n "$actual_version" && -n "$actual_build" ]] || fail "bundle version metadata is empty"
[[ -z "$EXPECTED_VERSION" || "$actual_version" == "$EXPECTED_VERSION" ]] \
    || fail "expected version $EXPECTED_VERSION, found $actual_version"
[[ -z "$EXPECTED_BUILD" || "$actual_build" == "$EXPECTED_BUILD" ]] \
    || fail "expected build $EXPECTED_BUILD, found $actual_build"

codesign --verify --deep --strict --verbose=2 "$APP"

if [[ "$SIGNING_LEVEL" != "ad-hoc" ]]; then
    signature="$(codesign -dvvv "$APP" 2>&1)"
    print -r -- "$signature" | rg -q '^Authority=Developer ID Application:' \
        || fail "app is not signed with a Developer ID Application certificate"
    print -r -- "$signature" | rg -q 'flags=.*runtime' \
        || fail "app signature does not enable the hardened runtime"
fi

if [[ "$SIGNING_LEVEL" == "notarized" ]]; then
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tiro-release-smoke.XXXXXX")"
PORT=""
for _ in {1..50}; do
    candidate=$((49152 + RANDOM % 16384))
    if ! nc -z 127.0.0.1 "$candidate" 2>/dev/null; then
        PORT="$candidate"
        break
    fi
done
[[ -n "$PORT" ]] || fail "could not find a free local port"
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

mkdir -p "$TEMP_ROOT/data" "$TEMP_ROOT/models"
env \
    TIRO_DATA_DIR="$TEMP_ROOT/data" \
    TIRO_MODEL_DIR="$TEMP_ROOT/models" \
    TIRO_WORKER_TOKEN="$TOKEN" \
    TIRO_PORT="$PORT" \
    "$WORKER" >"$TEMP_ROOT/worker.log" 2>&1 &
PID=$!

ready=0
for _ in {1..80}; do
    if curl -fsS \
        -H "X-Tiro-Worker-Token: $TOKEN" \
        "http://127.0.0.1:$PORT/api/status" >"$TEMP_ROOT/status.json" 2>/dev/null; then
        ready=1
        break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
        cat "$TEMP_ROOT/worker.log" >&2
        fail "packaged worker exited before becoming ready"
    fi
    sleep 0.25
done

if (( ! ready )); then
    cat "$TEMP_ROOT/worker.log" >&2
    fail "packaged worker did not become ready within 20 seconds"
fi

[[ "$(plutil -extract api_version raw "$TEMP_ROOT/status.json")" == "6" ]] \
    || fail "packaged worker reported an incompatible API version"
[[ "$(plutil -extract ready raw "$TEMP_ROOT/status.json")" == "true" ]] \
    || fail "packaged worker did not report ready"

curl -fsS -X POST \
    -H "X-Tiro-Worker-Token: $TOKEN" \
    "http://127.0.0.1:$PORT/api/shutdown" >/dev/null
wait "$PID"
PID=""

print "Release smoke check passed: Tiro $actual_version ($actual_build), $SIGNING_LEVEL"
