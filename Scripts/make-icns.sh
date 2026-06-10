#!/bin/bash
# 由 Resources/AppIcon-master.png（1024×1024 透明底）生成 Resources/AppIcon.icns
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="Resources/AppIcon-master.png"
SET="build/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "Resources/AppIcon.icns"
rm -rf "$SET"
echo "已生成: Resources/AppIcon.icns"
