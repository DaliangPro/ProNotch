#!/bin/bash
# 打分发用 DMG：通用二进制 release 构建 + 拖拽安装布局（应用 + Applications 快捷方式）
set -euo pipefail
cd "$(dirname "$0")/.."

# 回归测试闸门：核心逻辑（拼接/版本比较/翻译分块/语言映射）不过关不出包
echo "回归测试…"
if ! TEST_OUT=$(swift test 2>&1); then
    echo "$TEST_OUT" | tail -20
    echo "❌ 回归测试未通过，中止打包"
    exit 1
fi
echo "✅ 回归测试通过（$(echo "$TEST_OUT" | grep -oE "Executed [0-9]+ tests, with [0-9]+ failures" | tail -1)）"

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
