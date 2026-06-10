#!/bin/bash
# 打分发用 DMG：通用二进制 release 构建 + 拖拽安装布局（应用 + Applications 快捷方式）
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build-app.sh release universal

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/ProNotch-${VERSION}.dmg"
STAGING="build/dmg-staging"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/ProNotch.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "ProNotch ${VERSION}" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "已生成: $DMG"
echo "提醒: 未签名分发，用户首次打开需右键 → 打开，或执行:"
echo "  xattr -dr com.apple.quarantine /Applications/ProNotch.app"
