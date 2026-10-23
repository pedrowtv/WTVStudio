#!/bin/zsh
# Monta engine/dist/WTV Engine.app a partir do build SwiftPM (docs/ARQUITECTURA.md §4, D2).
# Uso: engine/scripts/make-app-bundle.sh [debug|release] [identidade de assinatura; por omissão "-" = ad-hoc]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${1:-release}"
IDENTITY="${2:--}"
ENGINE="$ROOT/engine"
APP="$ENGINE/dist/WTV Engine.app"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ENGINE" --scratch-path "$ENGINE/.build" --cache-path "$ROOT/.cache/swiftpm" --product wtv-engine
BIN="$ENGINE/.build/$CONFIG/wtv-engine"
[[ -x "$BIN" ]] || { echo "binário não encontrado: $BIN"; exit 1; }

echo "▸ a montar $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/wtv-engine"
cp "$ENGINE/bundle/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Interface construída (apps/studio/out/renderer) dentro do bundle: o motor serve-a em / sem depender
# de pastas externas (e de permissões de volumes amovíveis).
UI="$ROOT/apps/studio/out/renderer"
if [[ -d "$UI" ]]; then
  mkdir -p "$APP/Contents/Resources/ui"
  cp -R "$UI/." "$APP/Contents/Resources/ui/"
else
  echo "aviso: UI não construída ($UI); corra 'npm run studio:build' primeiro"
fi
# Bibliotecas dinâmicas trazidas pelas dependências (libsrt do HaishinKit, se existir no build)
find "$ENGINE/.build/$CONFIG" -maxdepth 1 -name "*.dylib" -exec cp {} "$APP/Contents/Frameworks/" \; 2>/dev/null || true
if [[ -n "$(ls -A "$APP/Contents/Frameworks" 2>/dev/null)" ]]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/wtv-engine" 2>/dev/null || true
fi

# exFAT cria ficheiros AppleDouble "._*" que o codesign recusa; remove-os (xattrs não são necessários).
export COPYFILE_DISABLE=1
dot_clean -m "$APP" 2>/dev/null || true
find "$APP" -name "._*" -delete

echo "▸ codesign ($IDENTITY)"
if [[ "$IDENTITY" == "-" ]]; then
  # Ad-hoc: sem hardened runtime (as entitlements de câmara/micro aplicam-se na mesma ao TCC pelo bundle id).
  codesign --force --sign - --entitlements "$ENGINE/bundle/entitlements.plist" "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENGINE/bundle/entitlements.plist" "$APP"
fi
find "$APP" -name "._*" -delete
codesign --verify --deep --strict "$APP" && echo "✓ $APP"
echo "▸ identidade:"; codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" || true
