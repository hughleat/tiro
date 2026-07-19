#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDKS=(/Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(N/))
SDK="${SDKS[1]:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$ROOT/.build/ModuleCache"

SDKROOT="$SDK" swiftc \
    -module-cache-path "$ROOT/.build/ModuleCache" \
    "$ROOT/Sources/Tiro/SupportPromptPolicy.swift" \
    "$ROOT/tests/TiroTests/SupportPromptPolicyAssertions.swift" \
    -o "$ROOT/.build/support-prompt-policy-tests"

"$ROOT/.build/support-prompt-policy-tests"
