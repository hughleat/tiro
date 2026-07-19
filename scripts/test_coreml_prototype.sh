#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PACKAGE="$ROOT/Prototypes/CoreML"
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
RUNTIME="$DEVELOPER_DIR/Library/Developer/usr/lib"
MODULE_CACHE="$PACKAGE/.build/ModuleCache"

mkdir -p "$MODULE_CACHE" "$PACKAGE/.build/SwiftPMCache"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
SWIFTPM_PACKAGECACHE_PATH="$PACKAGE/.build/SwiftPMCache" \
swift test --disable-sandbox --package-path "$PACKAGE" \
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
