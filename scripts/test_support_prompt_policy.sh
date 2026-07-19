#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDKS=(/Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk(N/))
SDK="${SDKS[1]:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p "$ROOT/.build/ModuleCache"

compile_and_run() {
    local state="$1"
    shift
    local executable="$ROOT/.build/support-prompt-policy-tests-$state"

    SDKROOT="$SDK" swiftc \
        -module-cache-path "$ROOT/.build/ModuleCache" \
        "$@" \
        "$ROOT/Sources/Tiro/BuildFeatures.swift" \
        "$ROOT/Sources/Tiro/SupportPromptPolicy.swift" \
        "$ROOT/tests/TiroTests/SupportPromptPolicyAssertions.swift" \
        -o "$executable"
    "$executable" "$state"
}

compile_and_run disabled
compile_and_run enabled -D TIRO_SPONSORSHIP_ENABLED
