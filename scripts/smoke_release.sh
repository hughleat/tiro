#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Tiro.app"
SIGNING_LEVEL="any"
EXPECTED_VERSION=""
EXPECTED_BUILD=""
EXPECTED_ENTITLEMENTS="$ROOT/native/Tiro.entitlements"

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
  -h, --help                 Show this help
USAGE
}

fail() {
    print -u2 "error: $*"
    exit 1
}

while (( $# > 0 )); do
    case "$1" in
        --app|--expected-version|--expected-build|--expected-entitlements)
            (( $# >= 2 )) || fail "$1 requires a value"
            option="$1"
            value="$2"
            shift 2
            case "$option" in
                --app) APP="${value:A}" ;;
                --expected-version) EXPECTED_VERSION="$value" ;;
                --expected-build) EXPECTED_BUILD="$value" ;;
                --expected-entitlements) EXPECTED_ENTITLEMENTS="${value:A}" ;;
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
[[ -f "$INFO" ]] || fail "Info.plist not found in app bundle"
[[ -f "$APP/Contents/Resources/Licenses/FluidAudio-Apache-2.0.txt" ]] \
    || fail "FluidAudio license is missing"
[[ -f "$APP/Contents/Resources/Licenses/Argmax-OSS-MIT.txt" ]] \
    || fail "Argmax OSS license is missing"
[[ -f "$APP/Contents/Resources/Licenses/Argmax-OSS-NOTICES.txt" ]] \
    || fail "Argmax OSS notices are missing"
[[ -z "$(find "$APP" -type f -name '*.py' -print -quit)" ]] \
    || fail "native release unexpectedly contains Python source"
[[ -z "$(find "$APP" -iname '*mlx*' -print -quit)" ]] \
    || fail "native release unexpectedly contains MLX"
[[ -z "$(find "$APP" \( -name '*.mlmodel' -o -name '*.mlmodelc' -o -name '*.mlpackage' \) -print -quit)" ]] \
    || fail "release unexpectedly contains model weights"
plutil -lint "$INFO" >/dev/null

actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
[[ -n "$actual_version" && -n "$actual_build" ]] || fail "bundle version metadata is empty"
[[ -z "$EXPECTED_VERSION" || "$actual_version" == "$EXPECTED_VERSION" ]] \
    || fail "expected version $EXPECTED_VERSION, found $actual_version"
[[ -z "$EXPECTED_BUILD" || "$actual_build" == "$EXPECTED_BUILD" ]] \
    || fail "expected build $EXPECTED_BUILD, found $actual_build"

deployment_target="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
version_code() {
    local version="$1"
    local major minor patch
    IFS=. read -r major minor patch <<< "$version"
    print $(( ${major:-0} * 10000 + ${minor:-0} * 100 + ${patch:-0} ))
}

while IFS= read -r -d '' candidate; do
    file -b "$candidate" | grep -q 'Mach-O' || continue
    lipo -archs "$candidate" | tr ' ' '\n' | grep -qx arm64 \
        || fail "native file lacks arm64 support: $candidate"
    minimum="$(vtool -show-build "$candidate" 2>/dev/null \
        | awk '/^[[:space:]]*minos / { print $2; exit }')"
    [[ -n "$minimum" ]] || fail "native file has no macOS build version: $candidate"
    (( $(version_code "$minimum") <= $(version_code "$deployment_target") )) \
        || fail "native file requires macOS $minimum: $candidate"
done < <(find "$APP/Contents" -type f -print0)

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

cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

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

print "Release smoke check passed: Tiro $actual_version ($actual_build), $SIGNING_LEVEL"
