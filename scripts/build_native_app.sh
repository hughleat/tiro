#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MODE="development"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/native/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/native/Info.plist")"
OUTPUT_DIR="$ROOT/dist"
ARCHIVE_DIR="$ROOT/dist/releases"
SIGNING_IDENTITY="${TIRO_SIGNING_IDENTITY:-}"
LOCAL_SIGNING_IDENTITY="${TIRO_LOCAL_SIGNING_IDENTITY:-Tiro Local Development}"
LOCAL_SIGNING_KEYCHAIN="${TIRO_LOCAL_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
NOTARY_PROFILE="${TIRO_NOTARY_PROFILE:-}"
ENTITLEMENTS="$ROOT/native/Tiro.entitlements"
SKIP_NOTARIZATION=0
DEVELOPMENT_PYTHON="$ROOT/.venv/bin/python"
RELEASE_ENVIRONMENT="$ROOT/.build/release-venv"
RELEASE_PYTHON="$RELEASE_ENVIRONMENT/bin/python"
RELEASE_PYTHON_VERSION="$(<"$ROOT/.python-version")"
DEPLOYMENT_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/native/Info.plist")"
TARGET_ARCHITECTURE="arm64"
BUILD_LOCK="$ROOT/.build/native-build.lock"
SUBMISSION_ARCHIVE=""
DMG_MOUNT_POINT=""
DMG_PARTIAL=""
DMG_STAGING=""
PENDING_ARTIFACT=""

usage() {
    cat <<'USAGE'
usage: build_native_app.sh [development|release|dmg|distribution] [options]

Modes:
  development   Native app using the checkout worker; locally signed (default)
  release       Self-contained local app; locally signed
  dmg           Self-contained ad-hoc-signed DMG for free distribution
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

TIRO_LOCAL_SIGNING_IDENTITY selects the certificate used for local builds. Run
scripts/setup_local_signing.sh once to create the default identity. If it is not
available, local builds fall back to ad-hoc signing.

TIRO_SIGNING_IDENTITY and TIRO_NOTARY_PROFILE provide credential-free defaults for
distribution. Store notarization credentials with notarytool rather than placing
secrets in this script or the repository.
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
        dmg|--dmg) MODE="dmg"; shift ;;
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

if [[ "$MODE" == "development" || "$MODE" == "release" ]]; then
    [[ -f "$LOCAL_SIGNING_KEYCHAIN" ]] \
        || fail "local signing keychain not found: $LOCAL_SIGNING_KEYCHAIN"
    LOCAL_IDENTITIES="$(security find-identity -v -p codesigning "$LOCAL_SIGNING_KEYCHAIN" 2>&1)" \
        || fail "could not read the local signing keychain: $LOCAL_SIGNING_KEYCHAIN"
fi

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

if [[ "$MODE" == "dmg" ]]; then
    [[ -z "$SIGNING_IDENTITY" && -z "$NOTARY_PROFILE" && "$SKIP_NOTARIZATION" -eq 0 ]] \
        || fail "dmg mode does not accept Developer ID or notarization options"
fi

sync_release_environment() {
    [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "$TARGET_ARCHITECTURE" ]] \
        || fail "self-contained builds require an Apple Silicon Mac"
    [[ -x "$DEVELOPMENT_PYTHON" ]] \
        || fail "self-contained builds require the project environment at: $DEVELOPMENT_PYTHON"

    env -u VIRTUAL_ENV \
        UV_PROJECT_ENVIRONMENT="$RELEASE_ENVIRONMENT" \
        UV_CACHE_DIR="$ROOT/.build/uv-cache" \
        "$DEVELOPMENT_PYTHON" -m uv sync --locked --extra bundle \
            --managed-python --python "$RELEASE_PYTHON_VERSION"
    "$DEVELOPMENT_PYTHON" "$ROOT/scripts/prepare_release_environment.py" \
        --lock "$ROOT/uv.lock" \
        --python "$RELEASE_PYTHON" \
        --target "$DEPLOYMENT_TARGET"
    if ! "$RELEASE_PYTHON" -c 'import importlib.util, sys; sys.exit(any(importlib.util.find_spec(name) is None for name in ("PyInstaller", "mlx_audio", "parakeet_mlx")))' >/dev/null 2>&1; then
        fail "release dependencies did not install correctly from uv.lock"
    fi
}

build_worker() {
    local work="$ROOT/.build/pyinstaller"
    export PYINSTALLER_CONFIG_DIR="$ROOT/.build/pyinstaller-config"
    rm -rf "$work"
    "$RELEASE_PYTHON" -m PyInstaller \
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
    "$DEVELOPMENT_PYTHON" "$ROOT/scripts/validate_macos_compatibility.py" \
        --target "$DEPLOYMENT_TARGET" \
        --architecture "$TARGET_ARCHITECTURE" \
        "$APP"
}

sign_locally() {
    local identity_matches identity_count fingerprint certificate_matches

    identity_matches="$(print -r -- "$LOCAL_IDENTITIES" | grep -F -- "\"$LOCAL_SIGNING_IDENTITY\"" || true)"
    if [[ -n "$identity_matches" ]]; then
        identity_count="$(print -r -- "$identity_matches" | wc -l | tr -d ' ')"
        [[ "$identity_count" == "1" ]] \
            || fail "multiple local Tiro signing identities are installed"
        fingerprint="$(print -r -- "$identity_matches" | awk '{print $2}')"
        sign_nested_code \
            --force \
            --keychain "$LOCAL_SIGNING_KEYCHAIN" \
            --sign "$fingerprint"
        return
    fi

    certificate_matches="$(security find-certificate -a -c "$LOCAL_SIGNING_IDENTITY" -Z "$LOCAL_SIGNING_KEYCHAIN" 2>/dev/null \
        | awk -v label="\"labl\"<blob>=\"$LOCAL_SIGNING_IDENTITY\"" '
            /^SHA-1 hash:/ { fingerprint = $3 }
            index($0, label) { print fingerprint }
        ' || true)"
    if [[ -n "$certificate_matches" ]]; then
        fail "the local signing identity is installed but unusable; unlock the keychain and rerun scripts/setup_local_signing.sh"
    fi

    print -u2 "warning: local signing identity not found; Accessibility permission may reset after rebuilds"
    print -u2 "run scripts/setup_local_signing.sh to create it"
    sign_nested_code --force --sign -
}

sign_nested_code() {
    local candidate bundle
    local -a sign_args

    sign_args=("$@")

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

    codesign "${sign_args[@]}" --generate-entitlement-der \
        --entitlements "$ENTITLEMENTS" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
}

sign_for_distribution() {
    sign_nested_code \
        --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp
}

create_archive() {
    local archive="$1"
    local partial="$archive.partial"
    rm -f "$archive" "$archive.sha256" "$partial"
    if ! ditto -c -k --keepParent --sequesterRsrc "$APP" "$partial"; then
        rm -f "$partial"
        return 1
    fi
    mv -f "$partial" "$archive"
}

create_dmg() {
    local image="$1"

    DMG_STAGING="$ROOT/.build/dmg-root"
    DMG_MOUNT_POINT="$ROOT/.build/dmg-mount"
    DMG_PARTIAL="${image:r}.partial.dmg"
    rm -rf "$DMG_STAGING" "$DMG_MOUNT_POINT"
    rm -f "$image" "$image.sha256" "$DMG_PARTIAL"
    mkdir -p "$DMG_STAGING" "$DMG_MOUNT_POINT"
    ditto "$APP" "$DMG_STAGING/Tiro.app"
    ln -s /Applications "$DMG_STAGING/Applications"

    hdiutil create -quiet \
        -fs HFS+ \
        -volname Tiro \
        -srcfolder "$DMG_STAGING" \
        -format UDZO \
        -ov "$DMG_PARTIAL"
    hdiutil verify "$DMG_PARTIAL" >/dev/null
    hdiutil attach -quiet -readonly -nobrowse \
        -mountpoint "$DMG_MOUNT_POINT" "$DMG_PARTIAL"

    [[ -d "$DMG_MOUNT_POINT/Tiro.app" ]] \
        || fail "DMG does not contain Tiro.app"
    [[ -L "$DMG_MOUNT_POINT/Applications" \
        && "$(readlink "$DMG_MOUNT_POINT/Applications")" == "/Applications" ]] \
        || fail "DMG does not contain the Applications shortcut"
    "$ROOT/scripts/smoke_release.sh" \
        --app "$DMG_MOUNT_POINT/Tiro.app" \
        --ad-hoc-only \
        --expected-entitlements "$ENTITLEMENTS" \
        --expected-version "$VERSION" \
        --expected-build "$BUILD_NUMBER"

    hdiutil detach -quiet "$DMG_MOUNT_POINT"
    rmdir "$DMG_MOUNT_POINT"
    DMG_MOUNT_POINT=""
    mv -f "$DMG_PARTIAL" "$image"
    DMG_PARTIAL=""
    rm -rf "$DMG_STAGING"
    DMG_STAGING=""
}

write_checksum() {
    local artifact="$1"

    (
        cd "$ARCHIVE_DIR"
        shasum -a 256 "${artifact:t}" > "${artifact:t}.sha256.partial"
        mv -f "${artifact:t}.sha256.partial" "${artifact:t}.sha256"
    )
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
    local mount_detached=1

    if [[ -n "$DMG_MOUNT_POINT" ]]; then
        if ! hdiutil detach -quiet "$DMG_MOUNT_POINT" >/dev/null 2>&1; then
            print -u2 "warning: could not detach DMG at $DMG_MOUNT_POINT"
            mount_detached=0
        fi
    fi
    [[ -z "$DMG_PARTIAL" ]] || rm -f "$DMG_PARTIAL" || true
    [[ -z "$DMG_STAGING" ]] || rm -rf "$DMG_STAGING" || true
    if [[ -n "$DMG_MOUNT_POINT" && "$mount_detached" -eq 1 ]]; then
        rm -rf "$DMG_MOUNT_POINT" || true
    fi
    if [[ -n "$PENDING_ARTIFACT" ]]; then
        rm -f "$PENDING_ARTIFACT" \
            "$PENDING_ARTIFACT.sha256" \
            "$PENDING_ARTIFACT.sha256.partial" || true
    fi
    [[ -z "$SUBMISSION_ARCHIVE" ]] \
        || rm -f "$SUBMISSION_ARCHIVE" "$SUBMISSION_ARCHIVE.partial" || true
    [[ -z "${archive:-}" ]] \
        || rm -f "$archive.partial" "$archive.sha256.partial" || true
    owner="$(cat "$BUILD_LOCK/pid" 2>/dev/null || true)"
    [[ "$owner" == "$$" ]] || return
    rm -f "$BUILD_LOCK/pid"
    rmdir "$BUILD_LOCK" 2>/dev/null || true
}

cd "$ROOT"
acquire_build_lock
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

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

if [[ "$MODE" == "development" || "$MODE" == "release" ]]; then
    sign_locally
    print "$APP"
    exit 0
fi

if [[ "$MODE" == "dmg" ]]; then
    sign_nested_code --force --sign -

    mkdir -p "$ARCHIVE_DIR"
    archive="$ARCHIVE_DIR/Tiro-$VERSION-$BUILD_NUMBER-macOS-arm64.dmg"
    PENDING_ARTIFACT="$archive"
    rm -f "$archive" "$archive.sha256" "$archive.sha256.partial"
    create_dmg "$archive"
    write_checksum "$archive"
    PENDING_ARTIFACT=""

    print "App: $APP"
    print "DMG: $archive"
    print "Checksum: $archive.sha256"
    exit 0
fi

sign_for_distribution
mkdir -p "$ARCHIVE_DIR"
suffix=""
(( SKIP_NOTARIZATION )) && suffix="-unnotarized"
archive="$ARCHIVE_DIR/Tiro-$VERSION-$BUILD_NUMBER-macOS-arm64$suffix.zip"
rm -f "$archive" "$archive.sha256" "$archive.partial" "$archive.sha256.partial"

if (( ! SKIP_NOTARIZATION )); then
    SUBMISSION_ARCHIVE="$ROOT/.build/Tiro-notarization-submission.zip"
    create_archive "$SUBMISSION_ARCHIVE"
    xcrun notarytool submit "$SUBMISSION_ARCHIVE" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$SUBMISSION_ARCHIVE"
    SUBMISSION_ARCHIVE=""
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
    "$ROOT/scripts/smoke_release.sh" --app "$APP" --notarized \
        --expected-entitlements "$ENTITLEMENTS" \
        --expected-version "$VERSION" --expected-build "$BUILD_NUMBER"
else
    "$ROOT/scripts/smoke_release.sh" --app "$APP" --developer-id \
        --expected-entitlements "$ENTITLEMENTS" \
        --expected-version "$VERSION" --expected-build "$BUILD_NUMBER"
fi

create_archive "$archive"
write_checksum "$archive"

print "App: $APP"
print "Archive: $archive"
print "Checksum: $archive.sha256"
