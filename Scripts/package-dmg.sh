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

# 用固定自签名证书签名（而非每次都变的 ad-hoc）：签名身份恒定，朋友首次授权后更新免重新授权。
# 缺证书则中止——ad-hoc 分发会让朋友每次更新都要重新授权（隐私授权按签名身份记忆）。
SIGN_ID="ProNotch Local Signing"
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "❌ 未找到固定签名证书「$SIGN_ID」，先运行 ./Scripts/create-signing-cert.sh 再发版"
    echo "   （ad-hoc 签名分发会导致朋友每次更新都要重新授权，已中止）"
    exit 1
fi
codesign --force --sign "$SIGN_ID" build/ProNotch.app
echo "✅ 已用固定证书签名（Designated Requirement 稳定，跨更新保权限）"
codesign -dr - build/ProNotch.app 2>&1 | grep "certificate leaf" || true

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
echo "提醒: 固定证书自签名（非 Apple 公证）。朋友首次安装需右键 →「打开」一次绕过 Gatekeeper；"
echo "      此后更新只要仍用本证书签名，隐私授权（屏幕录制等）自动保留、无需重新授权。"
