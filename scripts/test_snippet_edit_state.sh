#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/ModuleCache"

swiftc \
    -module-cache-path "$ROOT/.build/ModuleCache" \
    "$ROOT/Sources/Tiro/SnippetEditState.swift" \
    "$ROOT/tests/TiroTests/SnippetEditStateTests.swift" \
    -o "$ROOT/.build/snippet-edit-state-tests"

"$ROOT/.build/snippet-edit-state-tests"
