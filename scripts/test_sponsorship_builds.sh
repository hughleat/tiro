#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="$ROOT/.build/sponsorship-enabled"

"$ROOT/scripts/build_native_app.sh" development \
    --output-dir "$OUTPUT" \
    --enable-sponsorship
"$ROOT/scripts/smoke_release.sh" \
    --app "$OUTPUT/Tiro.app" \
    --expected-sponsorship true

print "Sponsorship-enabled app assertions passed"
