#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
RUNTIME="$DEVELOPER_DIR/Library/Developer/usr/lib"
MODULE_CACHE="$ROOT/.build/ModuleCache"

mkdir -p "$MODULE_CACHE" "$ROOT/.build/SwiftPMCache"
cd "$ROOT"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
SWIFTPM_PACKAGECACHE_PATH="$ROOT/.build/SwiftPMCache" \
swift test --disable-sandbox \
    -Xswiftc -module-cache-path \
    -Xswiftc "$MODULE_CACHE" \
    -Xswiftc -I \
    -Xswiftc "$FRAMEWORKS" \
    -Xswiftc -F \
    -Xswiftc "$FRAMEWORKS" \
    -Xlinker "-F$FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath \
    -Xlinker "$RUNTIME"
