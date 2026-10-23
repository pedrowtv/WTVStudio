#!/bin/zsh
# Monta engine-obs/dist/WTV Engine.app a partir do build do motor libobs (D23).
# Pré-requisitos: OBS compilado em ~/.cache/wtv-obs (docs/INSTALACAO.md), motor compilado em ~/.cache/wtv-obs/engine-build,
# UI compilada em apps/studio/out/renderer (npm run studio:build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBS="${WTV_OBS_DIR:-$HOME/.cache/wtv-obs}"
BUILD="$OBS/build"
DEPS="$OBS/obs-studio/.deps/obs-deps-2025-08-23-universal/lib"
BIN="$OBS/engine-build/wtv-engine"
UI="$ROOT/apps/studio/out/renderer"
APP="$ROOT/engine-obs/dist/WTV Engine.app"
IDENTITY="${CODESIGN_IDENT:--}"

[[ -x "$BIN" ]] || { echo "motor não compilado: $BIN"; exit 1; }
[[ -f "$UI/index.html" ]] || { echo "UI não construída ($UI); corra 'npm run studio:build'"; exit 1; }

echo "▸ a montar $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns" "$APP/Contents/Resources/ui" "$APP/Contents/Resources/obs-data"
cp "$BIN" "$APP/Contents/MacOS/wtv-engine"
cp "$BUILD/plugins/obs-ffmpeg/ffmpeg-mux/RelWithDebInfo/obs-ffmpeg-mux" "$APP/Contents/MacOS/"
cp "$ROOT/engine-obs/bundle/Info.plist" "$APP/Contents/Info.plist"

# libobs + renderers + dependências (as rpaths já são @executable_path/../Frameworks)
cp -R "$BUILD/libobs/RelWithDebInfo/libobs.framework" "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/libobs.framework/Headers" "$APP/Contents/Frameworks/libobs.framework/Versions/A/Headers"
cp "$BUILD/libobs-opengl/RelWithDebInfo/libobs-opengl.dylib" "$BUILD/libobs-metal/RelWithDebInfo/libobs-metal.dylib" "$APP/Contents/Frameworks/"
cp -R "$DEPS"/*.dylib "$APP/Contents/Frameworks/"
# plugins (resolve as ligações simbólicas do directório de staging)
for p in "$BUILD"/plugins/*/RelWithDebInfo/*.plugin; do
  n="$(basename "$p")"
  case "$n" in aja.plugin|obs-webrtc.plugin|obs-vst.plugin|mac-syphon.plugin|obs-x264.plugin|mac-avcapture-legacy.plugin) continue;; esac
  cp -RL "$p" "$APP/Contents/PlugIns/$n"
done
cp -R "$OBS/obs-studio/libobs/data/." "$APP/Contents/Resources/obs-data/"
cp -R "$UI/." "$APP/Contents/Resources/ui/"
# Remove as rpaths de desenvolvimento (senão a libobs carrega-se duas vezes: da cache e do bundle)
for rp in $(otool -l "$APP/Contents/MacOS/wtv-engine" | awk '/LC_RPATH/{getline; getline; print $2}'); do
  case "$rp" in @executable_path/*) ;; *) install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/wtv-engine";; esac
done
otool -l "$APP/Contents/MacOS/wtv-engine" | grep -q "@executable_path/../Frameworks" || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/wtv-engine"

# exFAT cria ficheiros AppleDouble "._*" que o codesign recusa
dot_clean -m "$APP" 2>/dev/null || true
find "$APP" -name "._*" -delete
find "$APP" -name ".DS_Store" -delete

echo "▸ codesign ($IDENTITY)"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --entitlements "$ROOT/engine-obs/bundle/entitlements.plist" "$APP"
else
  codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ROOT/engine-obs/bundle/entitlements.plist" "$APP"
fi
find "$APP" -name "._*" -delete # o codesign volta a criar AppleDouble no exFAT; a assinatura continua válida sem eles
codesign --verify --deep --strict "$APP" && echo "✓ $APP ($(du -sh "$APP" | cut -f1))"
