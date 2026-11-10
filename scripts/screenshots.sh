#!/usr/bin/env bash
# Launches build/Unrar.app in a few states and captures its window (used by CI).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=build/screenshots
mkdir -p "$OUT" build/demo
cp Tests/ArchiveKitTests/Fixtures/simple.rar "build/demo/Tài liệu dự án.rar"
cp Tests/ArchiveKitTests/Fixtures/password-headers.rar "build/demo/Bảo mật.rar"
swiftc -O scripts/window-id.swift -o build/window-id

shot() { # name, lang, [file]
  local name=$1 lang=$2 file=${3:-}
  pkill -x Unrar; sleep 1
  if [[ -n "$file" ]]; then
    open -a "$PWD/build/Unrar.app" "$file" --args -AppleLanguages "($lang)"
  else
    open "$PWD/build/Unrar.app" --args -AppleLanguages "($lang)"
  fi
  sleep 6
  osascript -e 'tell application "Unrar" to activate' >/dev/null 2>&1
  sleep 1
  local id; id=$(build/window-id Unrar)
  if [[ -n "$id" ]]; then
    screencapture -x -o -l "$id" "$OUT/$name.png"
  else
    screencapture -x "$OUT/$name.png"
  fi
  echo "captured $name (window ${id:-none})"
}

shot 1-welcome vi
shot 2-browser vi "build/demo/Tài liệu dự án.rar"
shot 3-password vi "build/demo/Bảo mật.rar"
shot 4-browser-en en "build/demo/Tài liệu dự án.rar"
pkill -x Unrar

# Small JPEG copies for quick viewing.
for f in "$OUT"/*.png; do
  j="${f%.png}.jpg"
  sips -s format jpeg -s formatOptions 70 -Z 1200 "$f" --out "$j" >/dev/null



done
