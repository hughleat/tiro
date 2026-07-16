#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"

zsh -n \
    "$ROOT/scripts/build_native_app.sh" \
    "$ROOT/scripts/setup_local_signing.sh" \
    "$ROOT/scripts/smoke_release.sh"
rg -q -F 'api_version raw "$TEMP_ROOT/status.json")" == "7"' "$ROOT/scripts/smoke_release.sh"
plutil -lint "$ROOT/native/Info.plist" "$ROOT/native/Tiro.entitlements" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ROOT/native/Tiro.entitlements")" == "true" ]]

help="$($ROOT/scripts/build_native_app.sh --help)"
print -r -- "$help" | rg -q 'distribution'
print -r -- "$help" | rg -q -- '--notary-profile'
print -r -- "$help" | rg -q -- '--build-number'
print -r -- "$help" | rg -q 'setup_local_signing.sh'

rg -q -F 'Tiro Local Development' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'extendedKeyUsage = codeSigning' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'security add-trusted-cert -r trustRoot -p codeSign' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'security delete-identity -Z "$fingerprint" -t "$KEYCHAIN"' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'codesign --verify --strict "$work/signing-test"' "$ROOT/scripts/setup_local_signing.sh"
rg -q -F 'TIRO_LOCAL_SIGNING_IDENTITY' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'TIRO_LOCAL_SIGNING_KEYCHAIN' "$ROOT/scripts/build_native_app.sh"

missing_keychain_output="$(TIRO_LOCAL_SIGNING_KEYCHAIN="$ROOT/does-not-exist.keychain" \
    "$ROOT/scripts/build_native_app.sh" development 2>&1 || true)"
if [[ "$missing_keychain_output" != *"local signing keychain not found"* ]]; then
    print -u2 "development build accepted a missing local signing keychain"
    exit 1
fi

if "$ROOT/scripts/build_native_app.sh" development --version invalid >/dev/null 2>&1; then
    print -u2 "invalid release version was accepted"
    exit 1
fi

if "$ROOT/scripts/build_native_app.sh" distribution --skip-notarization >/dev/null 2>&1; then
    print -u2 "distribution build accepted a missing signing identity"
    exit 1
fi

LOCK="$ROOT/.build/native-build.lock"
mkdir -p "$ROOT/.build"
if ! mkdir "$LOCK" 2>/dev/null; then
    print -u2 "cannot test native build locking while another build is active"
    exit 1
fi
print "$$" > "$LOCK/pid"
cleanup_lock_test() {
    [[ "$(cat "$LOCK/pid" 2>/dev/null || true)" == "$$" ]] || return
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup_lock_test EXIT INT TERM
if "$ROOT/scripts/build_native_app.sh" development >/dev/null 2>&1; then
    print -u2 "concurrent native build was not rejected"
    exit 1
fi
cleanup_lock_test
trap - EXIT INT TERM

LOGIN_MANAGER="$ROOT/Sources/Tiro/LoginItemManager.swift"
rg -q -F 'SMAppService.mainApp.register()' "$LOGIN_MANAGER"
rg -q -F 'SMAppService.mainApp.unregister()' "$LOGIN_MANAGER"
rg -q 'legacyCleanupFailed' "$LOGIN_MANAGER"
rg -q -F 'propertyList["Label"] as? String == "local.tiro.dictation"' "$LOGIN_MANAGER"
rg -q -F 'arguments[0] == "/usr/bin/open"' "$LOGIN_MANAGER"
rg -q -F 'lastPathComponent == "Tiro.app"' "$LOGIN_MANAGER"

register_line="$(rg -n -F 'try enableMainAppService()' "$LOGIN_MANAGER" | head -1 | cut -d: -f1)"
cleanup_line="$(rg -n -F 'try removeLegacyLaunchAgent()' "$LOGIN_MANAGER" | head -1 | cut -d: -f1)"
[[ "$register_line" -lt "$cleanup_line" ]]

print "Release engineering assertions passed"
