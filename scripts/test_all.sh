#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PYTHON="$ROOT/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    print -u2 "tests require the project environment at: $PYTHON"
    exit 1
fi

cd "$ROOT"
"$PYTHON" -m unittest discover -s tests
"$ROOT/scripts/test_app_paths_migration.sh"
"$ROOT/scripts/test_hotkey_state.sh"
"$ROOT/scripts/test_snippet_edit_state.sh"
"$ROOT/scripts/test_support_prompt_policy.sh"
"$ROOT/scripts/test_private_file_permissions.sh"
"$ROOT/scripts/test_release_engineering.sh"
"$ROOT/scripts/test_swift_worker.sh"
"$ROOT/scripts/test_coreml_production.sh"
"$ROOT/scripts/build_native_app.sh" development
"$ROOT/scripts/build_native_app.sh" dmg

print "All Tiro checks passed"
