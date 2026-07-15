#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Tiro.app"
MODE="${1:-development}"
PYTHON="$ROOT/.venv/bin/python"

case "$MODE" in
    development|--development) MODE="development" ;;
    release|--release) MODE="release" ;;
    *)
        print -u2 "usage: $0 [development|release]"
        exit 64
        ;;
esac

cd "$ROOT"

if [[ "$MODE" == "release" ]]; then
    if [[ ! -x "$PYTHON" ]]; then
        print -u2 "release build requires an existing Python environment at: $PYTHON"
        exit 1
    fi
    "$PYTHON" -m uv sync --frozen --extra bundle
    if ! "$PYTHON" -c 'import importlib.util, sys; sys.exit(any(importlib.util.find_spec(name) is None for name in ("PyInstaller", "mlx_audio", "parakeet_mlx")))' >/dev/null 2>&1; then
        print -u2 "release dependencies did not install correctly from uv.lock"
        exit 1
    fi
fi

mkdir -p "$ROOT/.build/ModuleCache" "$ROOT/.build/SwiftPMCache"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
export SWIFTPM_PACKAGECACHE_PATH="$ROOT/.build/SwiftPMCache"

swift build --disable-sandbox -c release \
    -Xswiftc -module-cache-path \
    -Xswiftc "$ROOT/.build/ModuleCache"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Tiro" "$APP/Contents/MacOS/Tiro"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"

if [[ "$MODE" == "release" ]]; then
    WORK="$ROOT/.build/pyinstaller"
    export PYINSTALLER_CONFIG_DIR="$ROOT/.build/pyinstaller-config"
    rm -rf "$WORK"
    "$PYTHON" -m PyInstaller \
        --noconfirm \
        --clean \
        --onedir \
        --name tiro-worker \
        --distpath "$WORK/dist" \
        --workpath "$WORK/work" \
        --specpath "$WORK" \
        --paths "$ROOT" \
        --collect-data mlx_audio \
        --collect-binaries mlx_audio \
        --collect-data mlx \
        --collect-binaries mlx \
        --hidden-import mlx_audio.stt \
        --hidden-import mlx_audio.stt.models.qwen3_asr \
        --hidden-import parakeet_mlx \
        --hidden-import mlx.core \
        --hidden-import mlx._reprlib_fix \
        --hidden-import huggingface_hub \
        "$ROOT/scripts/worker_entry.py"
    cp -R "$WORK/dist/tiro-worker" "$APP/Contents/Resources/worker"
    "$PYTHON" "$ROOT/scripts/validate_macos_compatibility.py" --update "$APP"
fi

# Ad-hoc signing is for local builds only. Distribution requires Developer ID
# signing, hardened runtime/entitlements, notarization, and stapling by a release pipeline.
codesign --force --deep --sign - \
    --requirements '=designated => identifier "local.tiro.dictation"' \
    "$APP"

print "$APP"
