#!/usr/bin/env bash
# Builds Unrar.app (universal: Apple Silicon + Intel) into ./build.
#
#   scripts/build-app.sh            # release build
#   CONFIG=debug scripts/build-app.sh
#   ARCHS="arm64" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/Unrar.app"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "▸ Building ($CONFIG, $ARCHS)"
swift build -c "$CONFIG" --product Unrar "${arch_flags[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --product Unrar "${arch_flags[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Unrar" "$APP/Contents/MacOS/Unrar"
cp Sources/UnrarApp/Info.plist "$APP/Contents/Info.plist"
cp -R Sources/UnrarApp/Resources/*.lproj "$APP/Contents/Resources/"
if [[ -f Sources/UnrarApp/Resources/AppIcon.icns ]]; then
  cp Sources/UnrarApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cp Sources/CUnrar/unrar/license.txt "$APP/Contents/Resources/UnRAR-License.txt"

echo "▸ Signing (ad hoc)"
codesign --force --deep --sign - "$APP"

echo "✓ Built $APP"
echo "  Open it with:  open \"$APP\""
