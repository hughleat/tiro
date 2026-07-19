#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tiro-migration-test.XXXXXX")"
TEMP_ROOT="${TEMP_ROOT:A}"
trap 'rm -rf "$TEMP_ROOT"' EXIT

CHECKOUT="$TEMP_ROOT/checkout"
SUPPORT="$TEMP_ROOT/support"
mkdir -p \
    "$CHECKOUT/Sources/Tiro" \
    "$CHECKOUT/data/audio/nested" \
    "$SUPPORT/data/audio/nested"
touch "$CHECKOUT/Package.swift" "$CHECKOUT/Sources/Tiro/AppDelegate.swift"
print -n 'source-new' > "$CHECKOUT/data/audio/nested/new.wav"
print -n 'source-value' > "$CHECKOUT/data/audio/nested/existing.wav"
print -n 'destination-value' > "$SUPPORT/data/audio/nested/existing.wav"

HARNESS="$TEMP_ROOT/main.swift"
cat > "$HARNESS" <<'SWIFT'
import Foundation

do {
    let report = try AppPaths.migrateLegacyProjectDataIfNeeded()
    print("copied=\(report.copiedItems.count)")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
SWIFT

export CLANG_MODULE_CACHE_PATH="$TEMP_ROOT/module-cache"
swiftc "$ROOT/Sources/Tiro/AppPaths.swift" "$HARNESS" -o "$TEMP_ROOT/migration-harness"
env \
    TIRO_PROJECT_ROOT="$CHECKOUT" \
    TIRO_DATA_DIR="$SUPPORT" \
    "$TEMP_ROOT/migration-harness" > "$TEMP_ROOT/output"

[[ "$(cat "$SUPPORT/data/audio/nested/new.wav")" == 'source-new' ]]
[[ "$(cat "$SUPPORT/data/audio/nested/existing.wav")" == 'destination-value' ]]
[[ "$(cat "$CHECKOUT/data/audio/nested/new.wav")" == 'source-new' ]]
[[ -f "$SUPPORT/.legacy-project-data-migrated-v4" ]]
[[ "$(cat "$SUPPORT/.legacy-project-root")" -ef "$CHECKOUT" ]]

# Installed releases can recover the checkout remembered by an earlier development run.
rm "$SUPPORT/.legacy-project-data-migrated-v4"
print -n 'remembered-root' > "$CHECKOUT/data/audio/remembered.wav"
(
    cd "$TEMP_ROOT"
    env \
        TIRO_DATA_DIR="$SUPPORT" \
        "$TEMP_ROOT/migration-harness" >/dev/null
)
[[ "$(cat "$SUPPORT/data/audio/remembered.wav")" == 'remembered-root' ]]
[[ -f "$SUPPORT/.legacy-project-data-migrated-v4" ]]

# A file/directory conflict is unresolved: preserve both sides and leave migration retryable.
FAIL_CHECKOUT="$TEMP_ROOT/failing-checkout"
FAIL_SUPPORT="$TEMP_ROOT/failing-support"
mkdir -p "$FAIL_CHECKOUT/Sources/Tiro" "$FAIL_CHECKOUT/data/audio" "$FAIL_SUPPORT/data"
touch "$FAIL_CHECKOUT/Package.swift" "$FAIL_CHECKOUT/Sources/Tiro/AppDelegate.swift"
print -n 'recording' > "$FAIL_CHECKOUT/data/audio/kept.wav"
print -n 'blocking-file' > "$FAIL_SUPPORT/data/audio"
if env \
    TIRO_PROJECT_ROOT="$FAIL_CHECKOUT" \
    TIRO_DATA_DIR="$FAIL_SUPPORT" \
    "$TEMP_ROOT/migration-harness" >/dev/null 2>&1; then
    print -u2 "expected conflicting migration to fail"
    exit 1
fi
[[ "$(cat "$FAIL_SUPPORT/data/audio")" == 'blocking-file' ]]
[[ "$(cat "$FAIL_CHECKOUT/data/audio/kept.wav")" == 'recording' ]]
[[ ! -e "$FAIL_SUPPORT/.legacy-project-data-migrated-v4" ]]

print "AppPaths migration assertions passed"
