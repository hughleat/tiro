#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
MODEL_ROOT="${TIRO_COREML_TEST_MODEL_ROOT:-$HOME/Library/Application Support/Tiro/Models/coreml}"
AUDIO="$ROOT/.build/coreml-smoke.wav"

mkdir -p "$ROOT/.build"
say "Tiro verifies native Core ML transcription." -o "$ROOT/.build/coreml-smoke.aiff"
afconvert -f WAVE -d LEI16@16000 -c 1 \
    "$ROOT/.build/coreml-smoke.aiff" "$AUDIO"

TIRO_COREML_TEST_MODEL_ROOT="$MODEL_ROOT" \
TIRO_COREML_TEST_AUDIO="$AUDIO" \
TIRO_COREML_TEST_DOWNLOAD=1 \
    "$ROOT/scripts/test_swift.sh"

rm -f "$ROOT/.build/coreml-smoke.aiff" "$AUDIO"
print "Production Core ML transcription passed"
