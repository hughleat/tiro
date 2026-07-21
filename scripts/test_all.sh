#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
dmg_args=()
if [[ -n "${TIRO_RELEASE_VERSION:-}" || -n "${TIRO_RELEASE_BUILD_NUMBER:-}" || -n "${TIRO_RELEASE_TAG:-}" ]]; then
    [[ -n "${TIRO_RELEASE_VERSION:-}" && -n "${TIRO_RELEASE_BUILD_NUMBER:-}" && -n "${TIRO_RELEASE_TAG:-}" ]] || {
        print -u2 "TIRO_RELEASE_VERSION, TIRO_RELEASE_BUILD_NUMBER, and TIRO_RELEASE_TAG must be set together"
        exit 1
    }
    dmg_args=(
        --version "$TIRO_RELEASE_VERSION"
        --build-number "$TIRO_RELEASE_BUILD_NUMBER"
        --release-tag "$TIRO_RELEASE_TAG"
    )
fi

cd "$ROOT"
"$ROOT/scripts/test_swift.sh"
"$ROOT/scripts/test_app_paths_migration.sh"
"$ROOT/scripts/test_hotkey_state.sh"
"$ROOT/scripts/test_snippet_edit_state.sh"
"$ROOT/scripts/test_support_prompt_policy.sh"
"$ROOT/scripts/test_private_file_permissions.sh"
"$ROOT/scripts/test_release_engineering.sh"
"$ROOT/scripts/test_coreml_production.sh"
"$ROOT/scripts/test_sponsorship_builds.sh"
"$ROOT/scripts/build_native_app.sh" development
"$ROOT/scripts/build_native_app.sh" dmg "${dmg_args[@]}"

print "All Tiro checks passed"
