#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/ModuleCache"

swiftc \
    -module-cache-path "$ROOT/.build/ModuleCache" \
    "$ROOT/Sources/Tiro/ModifierEventState.swift" \
    "$ROOT/tests/TiroTests/ModifierEventStateTests.swift" \
    -o "$ROOT/.build/modifier-event-state-tests"

"$ROOT/.build/modifier-event-state-tests"
