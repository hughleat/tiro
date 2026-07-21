#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-${GITHUB_REF_NAME:-}}"

if [[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-beta\.([0-9]+))?$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
    BETA_NUMBER="${BASH_REMATCH[3]:-}"
else
    echo "Release tags must look like v1.2.3 or v1.2.3-beta.1." >&2
    exit 1
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/native/Info.plist")"
BUILD_NUMBER="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/native/Info.plist")}"
if [[ "$VERSION" != "$PLIST_VERSION" ]]; then
    echo "Tag version $VERSION does not match Info.plist version $PLIST_VERSION." >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Build number must contain only dot-separated integers." >&2
    exit 1
fi

if [[ -n "$BETA_NUMBER" ]]; then
    RELEASE_NAME="Tiro $VERSION beta $BETA_NUMBER"
    PRERELEASE="true"
else
    RELEASE_NAME="Tiro $VERSION"
    PRERELEASE="false"
fi

printf 'version=%s\n' "$VERSION"
printf 'build_number=%s\n' "$BUILD_NUMBER"
printf 'asset_version=%s\n' "${TAG#v}"
printf 'release_name=%s\n' "$RELEASE_NAME"
printf 'prerelease=%s\n' "$PRERELEASE"
