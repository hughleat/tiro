#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Tiro.app"

cd "$ROOT"
mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/.build/SwiftPMCache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
export SWIFTPM_PACKAGECACHE_PATH="$ROOT/.build/SwiftPMCache"
swift build --disable-sandbox -c release \
    -Xswiftc -module-cache-path \
    -Xswiftc "$ROOT/.build/ModuleCache"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Tiro" "$APP/Contents/MacOS/Tiro"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - \
    --requirements '=designated => identifier "local.tiro.dictation"' \
    "$APP"

echo "$APP"
