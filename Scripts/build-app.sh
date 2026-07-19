#!/bin/bash
# 构建 ProNotch.app：纯 SwiftPM 编译 + 手工封装 bundle（不依赖 Xcode 工程）
# 用法: build-app.sh [debug|release] [universal]
#   第二个参数传 universal 时构建 Intel + Apple Silicon 通用二进制（用于分发）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VARIANT="${2:-native}"

if [ "$VARIANT" = "universal" ]; then
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    # 多架构产物在 .build/apple/Products/<首字母大写的配置名>/ 下
    CONFIG_DIR="$(echo "$CONFIG" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
    BIN=".build/apple/Products/$CONFIG_DIR/ProNotch"
else
    swift build -c "$CONFIG"
    BIN=".build/$CONFIG/ProNotch"
fi

APP_DIR="build/ProNotch.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/ProNotch"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Resources/TabIconLauncher.png "$APP_DIR/Contents/Resources/TabIconLauncher.png"
# 优先用与正式安装版相同的固定证书：TCC 权限（屏幕录制等）绑定 bundle id + 签名，
# 若 debug 构建以 ad-hoc 签名运行过，同 bundle id 换了签名会作废已授的录屏权限
#（2026-07 实测踩坑）；无固定证书（他人机器）才回退 ad-hoc
SIGN_ID="ProNotch Local Signing"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "$APP_DIR" >/dev/null 2>&1 \
        || codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
else
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "提示: 临时签名失败，不影响本机运行"
fi
echo "已生成: ${APP_DIR}（$(lipo -archs "$APP_DIR/Contents/MacOS/ProNotch" 2>/dev/null || echo 未知架构)）"
