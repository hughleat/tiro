#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Tiro.app"
SIGNING_LEVEL="any"
EXPECTED_VERSION=""
EXPECTED_BUILD=""
EXPECTED_ENTITLEMENTS="$ROOT/native/Tiro.entitlements"
INSTALLED_MODEL_DIR=""

usage() {
    cat <<'USAGE'
usage: smoke_release.sh [options]

Options:
  --app PATH                 App bundle to test (default: dist/Tiro.app)
  --ad-hoc-only              Require ad-hoc signatures with no signing authority
  --developer-id             Require Developer ID and hardened runtime
  --notarized                Also require a staple and Gatekeeper acceptance
  --expected-version VERSION Assert CFBundleShortVersionString
  --expected-build NUMBER    Assert CFBundleVersion
  --expected-entitlements PATH
                             Assert the app's exact entitlement policy
  --model-dir PATH           Also transcribe generated speech with every model
  -h, --help                 Show this help
USAGE
}

fail() {
    print -u2 "error: $*"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --app|--expected-version|--expected-build|--expected-entitlements|--model-dir)
            (( $# >= 2 )) || fail "$1 requires a value"
            option="$1"
            value="$2"
            shift 2
            case "$option" in
                --app) APP="${value:A}" ;;
                --expected-version) EXPECTED_VERSION="$value" ;;
                --expected-build) EXPECTED_BUILD="$value" ;;
                --expected-entitlements) EXPECTED_ENTITLEMENTS="${value:A}" ;;
                --model-dir) INSTALLED_MODEL_DIR="${value:A}" ;;
            esac
            ;;
        --developer-id)
            SIGNING_LEVEL="developer-id"
            shift
            ;;
        --ad-hoc-only)
            SIGNING_LEVEL="ad-hoc"
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
[[ -f "$EXPECTED_ENTITLEMENTS" ]] \
    || fail "expected entitlements not found: $EXPECTED_ENTITLEMENTS"
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

if [[ "$SIGNING_LEVEL" == "ad-hoc" ]]; then
    while IFS= read -r -d '' candidate; do
        [[ "$(file -b "$candidate")" == *"Mach-O"* ]] || continue
        signature="$(codesign -dvvv "$candidate" 2>&1)"
        print -r -- "$signature" | rg -q '^Signature=adhoc$' \
            || fail "community release contains a non-ad-hoc signature: $candidate"
        if print -r -- "$signature" | rg -q '^Authority='; then
            fail "community release contains a signing authority: $candidate"
        fi
    done < <(find "$APP/Contents" -type f -print0)
elif [[ "$SIGNING_LEVEL" != "any" ]]; then
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
MODEL_DIR="${INSTALLED_MODEL_DIR:-$TEMP_ROOT/models}"
[[ -z "$INSTALLED_MODEL_DIR" || -d "$MODEL_DIR/hub" ]] \
    || fail "model cache does not contain a hub directory: $MODEL_DIR"
codesign -d --entitlements - --xml "$APP" \
    >"$TEMP_ROOT/entitlements.plist" 2>/dev/null
plutil -lint "$TEMP_ROOT/entitlements.plist" >/dev/null \
    || fail "signed app has invalid entitlements"
plutil -convert binary1 -o "$TEMP_ROOT/expected-entitlements.plist" \
    "$EXPECTED_ENTITLEMENTS"
plutil -convert binary1 -o "$TEMP_ROOT/actual-entitlements.plist" \
    "$TEMP_ROOT/entitlements.plist"
cmp -s "$TEMP_ROOT/expected-entitlements.plist" "$TEMP_ROOT/actual-entitlements.plist" \
    || fail "signed app entitlements differ from the release policy"

env \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    TIRO_DATA_DIR="$TEMP_ROOT/data" \
    TIRO_MODEL_DIR="$MODEL_DIR" \
    "$WORKER" --self-test >"$TEMP_ROOT/ml-self-test.log" 2>&1 || {
        cat "$TEMP_ROOT/ml-self-test.log" >&2
        fail "packaged ML runtime self-test failed"
    }
rg -q -F 'Tiro ML runtime self-test passed' "$TEMP_ROOT/ml-self-test.log" \
    || fail "packaged ML runtime self-test did not finish"

env \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    TIRO_DATA_DIR="$TEMP_ROOT/data" \
    TIRO_MODEL_DIR="$MODEL_DIR" \
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

[[ "$(plutil -extract api_version raw "$TEMP_ROOT/status.json")" == "8" ]] \
    || fail "packaged worker reported an incompatible API version"
[[ "$(plutil -extract ready raw "$TEMP_ROOT/status.json")" == "true" ]] \
    || fail "packaged worker did not report ready"

if [[ -n "$INSTALLED_MODEL_DIR" ]]; then
    say "Tiro package verification" -o "$TEMP_ROOT/speech.aiff"
    afconvert -f WAVE -d LEI16@16000 -c 1 \
        "$TEMP_ROOT/speech.aiff" "$TEMP_ROOT/speech.wav"
    for model in compact parakeet-v2 qwen; do
        case "$model" in
            compact) expected_model="mlx-community/parakeet-tdt_ctc-110m" ;;
            parakeet-v2) expected_model="mlx-community/parakeet-tdt-0.6b-v2" ;;
            qwen) expected_model="mlx-community/Qwen3-ASR-0.6B-4bit" ;;
        esac
        curl -fsS -X POST \
            -H "X-Tiro-Worker-Token: $TOKEN" \
            -H "X-Parakeet-Model: $model" \
            "http://127.0.0.1:$PORT/api/preload" \
            >"$TEMP_ROOT/$model-preload.json"
        [[ "$(plutil -extract loaded_model raw "$TEMP_ROOT/$model-preload.json")" == "$expected_model" ]] \
            || fail "$model preloaded an unexpected model"

        curl -fsS -X POST \
            -H "X-Tiro-Worker-Token: $TOKEN" \
            -H "X-Parakeet-Model: $model" \
            -H "Content-Type: audio/wav" \
            --data-binary "@$TEMP_ROOT/speech.wav" \
            "http://127.0.0.1:$PORT/api/transcribe" \
            >"$TEMP_ROOT/$model-transcription.json"
        [[ "$(plutil -extract model raw "$TEMP_ROOT/$model-transcription.json")" == "$expected_model" ]] \
            || fail "$model transcribed with an unexpected model"
        text="$(plutil -extract text raw "$TEMP_ROOT/$model-transcription.json")"
        [[ -n "$text" ]] || fail "$model returned an empty transcription"
        print "Model smoke passed: $model — $text"
    done
fi

curl -fsS -X POST \
    -H "X-Tiro-Worker-Token: $TOKEN" \
    "http://127.0.0.1:$PORT/api/shutdown" >/dev/null
wait "$PID"
PID=""

print "Release smoke check passed: Tiro $actual_version ($actual_build), $SIGNING_LEVEL"
