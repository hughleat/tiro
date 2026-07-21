#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MODE="development"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/native/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/native/Info.plist")"
RELEASE_TAG=""
OUTPUT_DIR="$ROOT/dist"
ARCHIVE_DIR="$ROOT/dist/releases"
SIGNING_IDENTITY="${TIRO_SIGNING_IDENTITY:-}"
LOCAL_SIGNING_IDENTITY="${TIRO_LOCAL_SIGNING_IDENTITY:-Tiro Local Development}"
LOCAL_SIGNING_KEYCHAIN="${TIRO_LOCAL_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
NOTARY_PROFILE="${TIRO_NOTARY_PROFILE:-}"
ENTITLEMENTS="$ROOT/native/Tiro.entitlements"
SKIP_NOTARIZATION=0
SPONSORSHIP_ENABLED=0
DEPLOYMENT_TARGET="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/native/Info.plist")"
TARGET_ARCHITECTURE="arm64"
DMG_TEMPLATE_SHA256="d4dde813f3fe08e56783a99a75ae4e729f2dc401f4eeb812bd658fcb0b90f277"
BUILD_LOCK="$ROOT/.build/native-build.lock"
SUBMISSION_ARCHIVE=""
DMG_MOUNT_POINT=""
DMG_PARTIAL=""
DMG_STAGING=""
DMG_LAYOUT_EXPECTED=""
PENDING_ARTIFACT=""

usage() {
    cat <<'USAGE'
usage: build_native_app.sh [development|release|dmg|distribution] [options]

Modes:
  development   Native local app; locally signed (default)
  release       Native local app; locally signed
  dmg           Native ad-hoc-signed DMG for free distribution
  distribution Native Developer ID app, archive, and checksum

Options:
  --version VERSION          CFBundleShortVersionString (for example 1.2.0)
  --build-number NUMBER      CFBundleVersion (for example 42)
  --release-tag TAG          Published release tag (for example v1.2.0-beta.1)
  --output-dir PATH          App output directory (default: dist)
  --archive-dir PATH         Distribution archive directory (default: dist/releases)
  --signing-identity NAME    Developer ID Application identity
  --entitlements PATH        Main-app entitlements plist
  --notary-profile NAME      notarytool keychain profile
  --skip-notarization        Signing test only; artifact is not ready to distribute
  --enable-sponsorship       Include support links and periodic reminders
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
        --version|--build-number|--release-tag|--output-dir|--archive-dir|--signing-identity|--entitlements|--notary-profile)
            (( $# >= 2 )) || fail "$1 requires a value"
            option="$1"
            value="$2"
            shift 2
            case "$option" in
                --version) VERSION="$value" ;;
                --build-number) BUILD_NUMBER="$value" ;;
                --release-tag) RELEASE_TAG="$value" ;;
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
        --enable-sponsorship)
            SPONSORSHIP_ENABLED=1
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
[[ -z "$RELEASE_TAG" || "$RELEASE_TAG" == "v$VERSION" || "$RELEASE_TAG" == "v$VERSION-beta."<-> ]] \
    || fail "--release-tag must match --version"
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

detach_dmg() {
    local mount_point="$1"

    hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 \
        || hdiutil detach -quiet -force "$mount_point" >/dev/null 2>&1
}

create_dmg() {
    local image="$1"

    DMG_STAGING="$ROOT/.build/Tiro-dmg-work.dmg"
    DMG_MOUNT_POINT="$ROOT/.build/dmg-mount"
    DMG_LAYOUT_EXPECTED="$ROOT/.build/Tiro-dmg-layout.expected"
    DMG_PARTIAL="${image:r}.partial.dmg"
    if mount | grep -F " on $DMG_MOUNT_POINT (" >/dev/null; then
        detach_dmg "$DMG_MOUNT_POINT" \
            || fail "could not detach stale DMG mount at $DMG_MOUNT_POINT"
    fi
    rm -rf "$DMG_STAGING" "$DMG_MOUNT_POINT"
    rm -f "$image" "$image.sha256" "$DMG_PARTIAL" "$DMG_LAYOUT_EXPECTED"
    mkdir -p "$DMG_MOUNT_POINT"

    local template="$ROOT/native/Assets/TiroDMGTemplate.dmg"
    local template_sha256="$(shasum -a 256 "$template" | awk '{ print $1 }')"
    [[ "$template_sha256" == "$DMG_TEMPLATE_SHA256" ]] \
        || fail "DMG template checksum does not match its reviewed layout"
    hdiutil convert -quiet "$ROOT/native/Assets/TiroDMGTemplate.dmg" \
        -format UDRW -o "$DMG_STAGING"
    hdiutil resize -quiet -size 128m "$DMG_STAGING"
    hdiutil attach -quiet -nobrowse -mountpoint "$DMG_MOUNT_POINT" \
        "$DMG_STAGING"
    cp "$DMG_MOUNT_POINT/.DS_Store" "$DMG_LAYOUT_EXPECTED"
    strings "$DMG_LAYOUT_EXPECTED" | grep -Fx '{{200, 120}, {660, 420}}' >/dev/null \
        || fail "DMG template has unexpected Finder window bounds"
    cmp -s "$DMG_MOUNT_POINT/.background.png" \
        "$ROOT/native/Assets/TiroDMGBackground.png" \
        || fail "DMG template background does not match its source asset"
    rm -rf "$DMG_MOUNT_POINT/Tiro.app"
    ditto "$APP" "$DMG_MOUNT_POINT/Tiro.app"
    detach_dmg "$DMG_MOUNT_POINT"
    rmdir "$DMG_MOUNT_POINT"
    DMG_MOUNT_POINT=""
    hdiutil convert -quiet "$DMG_STAGING" -format UDZO -o "$DMG_PARTIAL"
    hdiutil verify "$DMG_PARTIAL" >/dev/null
    DMG_MOUNT_POINT="$ROOT/.build/dmg-mount"
    mkdir -p "$DMG_MOUNT_POINT"
    hdiutil attach -quiet -readonly -nobrowse \
        -mountpoint "$DMG_MOUNT_POINT" "$DMG_PARTIAL"

    [[ -d "$DMG_MOUNT_POINT/Tiro.app" ]] \
        || fail "DMG does not contain Tiro.app"
    [[ -L "$DMG_MOUNT_POINT/Applications" \
        && "$(readlink "$DMG_MOUNT_POINT/Applications")" == "/Applications" ]] \
        || fail "DMG does not contain the Applications shortcut"
    [[ -f "$DMG_MOUNT_POINT/.background.png" ]] \
        || fail "DMG does not contain its generated background"
    cmp -s "$DMG_MOUNT_POINT/.DS_Store" "$DMG_LAYOUT_EXPECTED" \
        || fail "DMG does not contain the expected Finder layout"
    "$ROOT/scripts/smoke_release.sh" \
        --app "$DMG_MOUNT_POINT/Tiro.app" \
        --ad-hoc-only \
        --expected-entitlements "$ENTITLEMENTS" \
        --expected-version "$VERSION" \
        --expected-build "$BUILD_NUMBER" \
        --expected-release-tag "$RELEASE_TAG" \
        --expected-sponsorship "$sponsorship_value"

    detach_dmg "$DMG_MOUNT_POINT"
    rmdir "$DMG_MOUNT_POINT"
    DMG_MOUNT_POINT=""
    mv -f "$DMG_PARTIAL" "$image"
    DMG_PARTIAL=""
    rm -rf "$DMG_STAGING"
    DMG_STAGING=""
    rm -f "$DMG_LAYOUT_EXPECTED"
    DMG_LAYOUT_EXPECTED=""
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
        if ! detach_dmg "$DMG_MOUNT_POINT"; then
            print -u2 "warning: could not detach DMG at $DMG_MOUNT_POINT"
            mount_detached=0
        fi
    fi
    [[ -z "$DMG_PARTIAL" ]] || rm -f "$DMG_PARTIAL" || true
    [[ -z "$DMG_STAGING" ]] || rm -rf "$DMG_STAGING" || true
    [[ -z "$DMG_LAYOUT_EXPECTED" ]] || rm -f "$DMG_LAYOUT_EXPECTED" || true
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

mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/.build/SwiftPMCache" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
export SWIFTPM_PACKAGECACHE_PATH="$ROOT/.build/SwiftPMCache"

swift_args=(
    --disable-sandbox
    -c release
    -Xswiftc -module-cache-path \
    -Xswiftc "$ROOT/.build/ModuleCache"
)
if (( SPONSORSHIP_ENABLED )); then
    swift_args+=(-Xswiftc -D -Xswiftc TIRO_SPONSORSHIP_ENABLED)
fi
swift build "${swift_args[@]}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Tiro" "$APP/Contents/MacOS/Tiro"
cp "$ROOT/.build/release/TiroCommand" "$APP/Contents/Helpers/tiro"
chmod 755 "$APP/Contents/Helpers/tiro"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/native/Assets/Tiro.icns" "$APP/Contents/Resources/Tiro.icns"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/Tiro-MIT.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
cp "$ROOT/.build/checkouts/FluidAudio/LICENSE" \
    "$APP/Contents/Resources/Licenses/FluidAudio-Apache-2.0.txt"
cp "$ROOT/.build/checkouts/argmax-oss-swift/LICENSE" \
    "$APP/Contents/Resources/Licenses/Argmax-OSS-MIT.txt"
cp "$ROOT/.build/checkouts/argmax-oss-swift/NOTICES" \
    "$APP/Contents/Resources/Licenses/Argmax-OSS-NOTICES.txt"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
if [[ -n "$RELEASE_TAG" ]]; then
    /usr/libexec/PlistBuddy -c "Add :TiroReleaseTag string $RELEASE_TAG" "$APP/Contents/Info.plist"
fi
if (( SPONSORSHIP_ENABLED )); then
    sponsorship_value=true
else
    sponsorship_value=false
fi
/usr/libexec/PlistBuddy -c "Set :TiroSponsorshipEnabled $sponsorship_value" "$APP/Contents/Info.plist"

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
        --expected-version "$VERSION" --expected-build "$BUILD_NUMBER" \
        --expected-sponsorship "$sponsorship_value"
else
    "$ROOT/scripts/smoke_release.sh" --app "$APP" --developer-id \
        --expected-entitlements "$ENTITLEMENTS" \
        --expected-version "$VERSION" --expected-build "$BUILD_NUMBER" \
        --expected-sponsorship "$sponsorship_value"
fi

create_archive "$archive"
write_checksum "$archive"

print "App: $APP"
print "Archive: $archive"
print "Checksum: $archive.sha256"
