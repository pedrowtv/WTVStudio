#!/bin/bash
# Arranca o motor libobs em desenvolvimento (sem token, loopback), a servir a UI compilada do Electron.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBS="$HOME/.cache/wtv-obs"
export DYLD_FRAMEWORK_PATH="$OBS/build/libobs/RelWithDebInfo"
export DYLD_LIBRARY_PATH="$OBS/obs-studio/.deps/obs-deps-2025-08-23-universal/lib"
exec "$OBS/engine-build/wtv-engine" --dev --port "${PORT:-7421}" --ui "$ROOT/apps/studio/out/renderer" "$@"
