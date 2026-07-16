#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MODE="development"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/native/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/native/Info.plist")"
OUTPUT_DIR="$ROOT/dist"
ARCHIVE_DIR="$ROOT/dist/releases"
SIGNING_IDENTITY="${TIRO_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${TIRO_NOTARY_PROFILE:-}"
ENTITLEMENTS="$ROOT/native/Tiro.entitlements"
SKIP_NOTARIZATION=0
PYTHON="$ROOT/.venv/bin/python"
BUILD_LOCK="$ROOT/.build/native-build.lock"

usage() {
    cat <<'USAGE'
usage: build_native_app.sh [development|release|distribution] [options]

Modes:
  development   Native app using the checkout worker; ad-hoc signed (default)
  release       Self-contained local app; ad-hoc signed
  distribution Self-contained Developer ID app, archive, and checksum

Options:
  --version VERSION          CFBundleShortVersionString (for example 1.2.0)
  --build-number NUMBER      CFBundleVersion (for example 42)
  --output-dir PATH          App output directory (default: dist)
  --archive-dir PATH         Distribution archive directory (default: dist/releases)
  --signing-identity NAME    Developer ID Application identity
  --entitlements PATH        Main-app entitlements plist
  --notary-profile NAME      notarytool keychain profile
  --skip-notarization        Signing test only; artifact is not ready to distribute
  -h, --help                 Show this help

TIRO_SIGNING_IDENTITY and TIRO_NOTARY_PROFILE provide credential-free defaults for
the corresponding options. Store notarization credentials with notarytool rather
than placing secrets in this script or the repository.
USAGE
}

fail() {
    print -u2 "error: $*"
    exit 1
}

if (( $# > 0 )); then
    case "$1" in
        development|--development) MODE="development"; shift ;;
        release|--release) MODE="release"; shift ;;
        distribution|--distribution) MODE="distribution"; shift ;;
    esac
fi

while (( $# > 0 )); do
    case "$1" in
        --version|--build-number|--output-dir|--archive-dir|--signing-identity|--entitlements|--notary-profile)
            (( $# >= 2 )) || fail "$1 requires a value"
            option="$1"
            value="$2"
            shift 2
            case "$option" in
                --version) VERSION="$value" ;;
                --build-number) BUILD_NUMBER="$value" ;;
                --output-dir) OUTPUT_DIR="${value:A}" ;;
                --archive-dir) ARCHIVE_DIR="${value:A}" ;;
                --signing-identity) SIGNING_IDENTITY="$value" ;;
                --entitlements) ENTITLEMENTS="${value:A}" ;;
                --notary-profile) NOTARY_PROFILE="$value" ;;
            esac
            ;;
        --skip-notarization)
            SKIP_NOTARIZATION=1
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

[[ "$VERSION" == <->(|.<->)(|.<->) ]] \
    || fail "--version must contain one to three dot-separated integers"
[[ "$BUILD_NUMBER" == <->(|.<->)* ]] \
    || fail "--build-number must begin with an integer and contain only integers and periods"
[[ "$BUILD_NUMBER" != *[^0-9.]* && "$BUILD_NUMBER" != *..* && "$BUILD_NUMBER" != *. ]] \
    || fail "--build-number must begin with an integer and contain only integers and periods"
[[ -f "$ENTITLEMENTS" ]] || fail "entitlements file not found: $ENTITLEMENTS"

APP="$OUTPUT_DIR/Tiro.app"

if [[ "$MODE" == "distribution" ]]; then
    [[ -n "$SIGNING_IDENTITY" ]] \
        || fail "distribution mode requires --signing-identity or TIRO_SIGNING_IDENTITY"
    identities="$(security find-identity -v -p codesigning)"
    print -r -- "$identities" | grep -F -- "$SIGNING_IDENTITY" | grep -F 'Developer ID Application:' >/dev/null \
        || fail "Developer ID Application identity not found in the keychain: $SIGNING_IDENTITY"
    if [[ -z "$NOTARY_PROFILE" && "$SKIP_NOTARIZATION" -eq 0 ]]; then
        fail "distribution mode requires --notary-profile (or --skip-notarization for a signing-only test)"
    fi
fi

sync_release_environment() {
    [[ -x "$PYTHON" ]] \
        || fail "self-contained builds require an existing Python environment at: $PYTHON"

    "$PYTHON" -m uv sync --frozen --extra bundle
    if ! "$PYTHON" -c 'import importlib.util, sys; sys.exit(any(importlib.util.find_spec(name) is None for name in ("PyInstaller", "mlx_audio", "parakeet_mlx")))' >/dev/null 2>&1; then
        fail "release dependencies did not install correctly from uv.lock"
    fi
}

build_worker() {
    local work="$ROOT/.build/pyinstaller"
    export PYINSTALLER_CONFIG_DIR="$ROOT/.build/pyinstaller-config"
    rm -rf "$work"
    "$PYTHON" -m PyInstaller \
        --noconfirm \
        --clean \
        --onedir \
        --name tiro-worker \
        --distpath "$work/dist" \
        --workpath "$work/work" \
        --specpath "$work" \
        --paths "$ROOT" \
        --collect-data mlx_audio \
        --collect-binaries mlx_audio \
        --collect-data mlx \
        --collect-binaries mlx \
        --hidden-import mlx_audio.stt \
        --hidden-import mlx_audio.stt.models.qwen3_asr \
        --hidden-import parakeet_mlx \
        --hidden-import mlx.core \
        --hidden-import mlx._reprlib_fix \
        --hidden-import huggingface_hub \
        "$ROOT/scripts/worker_entry.py"
    cp -R "$work/dist/tiro-worker" "$APP/Contents/Resources/worker"
    "$PYTHON" "$ROOT/scripts/validate_macos_compatibility.py" --update "$APP"
}

sign_ad_hoc() {
    # The stable requirement helps local rebuilds retain Accessibility permission.
    codesign --force --deep --sign - \
        --requirements '=designated => identifier "local.tiro.dictation"' \
        "$APP"
}

sign_for_distribution() {
    local candidate bundle
    local -a sign_args

    sign_args=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)

    # Sign every nested Mach-O before any enclosing code bundle, then sign the app.
    while IFS= read -r -d '' candidate; do
        [[ "$candidate" == "$APP/Contents/MacOS/Tiro" ]] && continue
        if file -b "$candidate" | grep -q 'Mach-O'; then
            codesign "${sign_args[@]}" "$candidate"
        fi
    done < <(find "$APP/Contents" -depth -type f -print0)

    while IFS= read -r -d '' bundle; do
        codesign "${sign_args[@]}" "$bundle"
    done < <(find "$APP/Contents" -depth -type d \( \
        -name '*.app' -o -name '*.appex' -o -name '*.framework' -o \
        -name '*.plugin' -o -name '*.xpc' \) -print0)

    codesign "${sign_args[@]}" --entitlements "$ENTITLEMENTS" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
}

create_archive() {
    local archive="$1"
    rm -f "$archive" "$archive.sha256"
    ditto -c -k --keepParent --sequesterRsrc "$APP" "$archive"
}

acquire_build_lock() {
    mkdir -p "$ROOT/.build"
    if ! mkdir "$BUILD_LOCK" 2>/dev/null; then
        owner="$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)"
        if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$BUILD_LOCK/pid"
            rmdir "$BUILD_LOCK" 2>/dev/null || true
            mkdir "$BUILD_LOCK" 2>/dev/null \
                || fail "another Tiro build is using $BUILD_LOCK"
        else
            fail "another Tiro build is running${owner:+ (PID $owner)}"
        fi
    fi
    print "$$" > "$BUILD_LOCK/pid"
    trap release_build_lock EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

release_build_lock() {
    owner="$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)"
    [[ "$owner" == "$$" ]] || return
    rm -f "$BUILD_LOCK/pid"
    rmdir "$BUILD_LOCK" 2>/dev/null || true
}

cd "$ROOT"
acquire_build_lock

if [[ "$MODE" != "development" ]]; then
    sync_release_environment
fi

mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/.build/SwiftPMCache" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
export SWIFTPM_PACKAGECACHE_PATH="$ROOT/.build/SwiftPMCache"

swift build --disable-sandbox -c release \
    -Xswiftc -module-cache-path \
    -Xswiftc "$ROOT/.build/ModuleCache"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Tiro" "$APP/Contents/MacOS/Tiro"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

if [[ "$MODE" != "development" ]]; then
    build_worker
fi

if [[ "$MODE" != "distribution" ]]; then
    sign_ad_hoc
    print "$APP"
    exit 0
fi

sign_for_distribution
mkdir -p "$ARCHIVE_DIR"
suffix=""
(( SKIP_NOTARIZATION )) && suffix="-unnotarized"
archive="$ARCHIVE_DIR/Tiro-$VERSION-$BUILD_NUMBER-macOS-arm64$suffix.zip"
create_archive "$archive"

if (( ! SKIP_NOTARIZATION )); then
    xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
    "$ROOT/scripts/smoke_release.sh" --app "$APP" --notarized \
        --expected-version "$VERSION" --expected-build "$BUILD_NUMBER"
    create_archive "$archive"
else
    "$ROOT/scripts/smoke_release.sh" --app "$APP" --developer-id \
        --expected-version "$VERSION" --expected-build "$BUILD_NUMBER"
fi

(
    cd "$ARCHIVE_DIR"
    shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
)

print "App: $APP"
print "Archive: $archive"
print "Checksum: $archive.sha256"
