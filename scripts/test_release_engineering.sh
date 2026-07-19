#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MACOS_14_WORKFLOW="$ROOT/.github/workflows/macos-14.yml"

zsh -n \
    "$ROOT/scripts/build_native_app.sh" \
    "$ROOT/scripts/setup_local_signing.sh" \
    "$ROOT/scripts/smoke_release.sh"
"$ROOT/.venv/bin/python" -m py_compile \
    "$ROOT/scripts/prepare_release_environment.py" \
    "$ROOT/scripts/validate_macos_compatibility.py" \
    "$ROOT/scripts/worker_entry.py"
rg -q -F 'api_version raw "$TEMP_ROOT/status.json")" == "7"' "$ROOT/scripts/smoke_release.sh"
rg -q -F '"$WORKER" --self-test' "$ROOT/scripts/smoke_release.sh"
rg -q -F 'expected-entitlements.plist' "$ROOT/scripts/smoke_release.sh"
rg -q -F -- '--expected-entitlements "$ENTITLEMENTS"' "$ROOT/scripts/build_native_app.sh"
rg -q -F -- '--target "$DEPLOYMENT_TARGET"' "$ROOT/scripts/build_native_app.sh"
rg -q -F -- '--python "$RELEASE_PYTHON_VERSION"' "$ROOT/scripts/build_native_app.sh"
rg -q -F -- 'uv sync --locked' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'Tiro-notarization-submission.zip' "$ROOT/scripts/build_native_app.sh"
archive_cleanup_line="$(rg -n -F 'rm -f "$archive" "$archive.sha256" "$archive.partial"' "$ROOT/scripts/build_native_app.sh" | tail -1 | cut -d: -f1)"
notarization_line="$(rg -n -F 'xcrun notarytool submit' "$ROOT/scripts/build_native_app.sh" | head -1 | cut -d: -f1)"
smoke_line="$(rg -n -F 'smoke_release.sh" --app "$APP" --notarized' "$ROOT/scripts/build_native_app.sh" | head -1 | cut -d: -f1)"
[[ "$archive_cleanup_line" -lt "$notarization_line" ]]
[[ "$archive_cleanup_line" -lt "$smoke_line" ]]
rg -q -F 'mv -f "$partial" "$archive"' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'hdiutil create -quiet' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'hdiutil verify "$DMG_PARTIAL"' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'hdiutil attach -quiet -readonly -nobrowse' "$ROOT/scripts/build_native_app.sh"
rg -q -F 'ln -s /Applications "$DMG_STAGING/Applications"' "$ROOT/scripts/build_native_app.sh"
rg -q -F '"$ROOT/scripts/build_native_app.sh" dmg' "$ROOT/scripts/test_all.sh"
rg -q -F -- '--app "$DMG_MOUNT_POINT/Tiro.app"' "$ROOT/scripts/build_native_app.sh"
rg -q -F -- '--ad-hoc-only' "$ROOT/scripts/build_native_app.sh"
rg -q -F "'^Signature=adhoc$'" "$ROOT/scripts/smoke_release.sh"
if rg -q -F -- '--update' "$ROOT/scripts/build_native_app.sh"; then
    print -u2 "release build still rewrites its deployment target"
    exit 1
fi
plutil -lint "$ROOT/native/Info.plist" "$ROOT/native/Tiro.entitlements" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$ROOT/native/Tiro.entitlements")" == "true" ]]
rg -q -F 'runs-on: macos-14' "$MACOS_14_WORKFLOW"
rg -q -F 'actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$MACOS_14_WORKFLOW"
rg -q -F 'persist-credentials: false' "$MACOS_14_WORKFLOW"
rg -q -F 'DEVELOPER_DIR: /Applications/Xcode_16.2.app/Contents/Developer' "$MACOS_14_WORKFLOW"
rg -q -F 'run: brew install ripgrep' "$MACOS_14_WORKFLOW"
rg -q -F "run: swift --version | grep -q 'Swift version 6\\.'" "$MACOS_14_WORKFLOW"
rg -q -F 'run: ./scripts/test_all.sh' "$MACOS_14_WORKFLOW"
rg -q -F 'uv sync --locked --extra bundle' "$MACOS_14_WORKFLOW"
rg -q -F 'uv python install "$(cat .python-version)"' "$MACOS_14_WORKFLOW"
rg -q -F 'version: "0.11.28"' "$MACOS_14_WORKFLOW"

help="$($ROOT/scripts/build_native_app.sh --help)"
print -r -- "$help" | rg -q 'distribution'
print -r -- "$help" | rg -q 'dmg'
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

for credential_option in \
    "--signing-identity Developer" \
    "--notary-profile profile" \
    "--skip-notarization"; do
    if "$ROOT/scripts/build_native_app.sh" dmg ${(z)credential_option} >/dev/null 2>&1; then
        print -u2 "dmg build accepted a distribution credential option"
        exit 1
    fi
done

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
