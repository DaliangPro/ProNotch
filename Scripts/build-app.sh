#!/bin/bash
# 构建 NotchHub.app：纯 SwiftPM 编译 + 手工封装 bundle（不依赖 Xcode 工程）
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
    BIN=".build/apple/Products/$CONFIG_DIR/NotchHub"
else
    swift build -c "$CONFIG"
    BIN=".build/$CONFIG/NotchHub"
fi

APP_DIR="build/NotchHub.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/NotchHub"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "提示: 临时签名失败，不影响本机运行"
echo "已生成: $APP_DIR（$(lipo -archs "$APP_DIR/Contents/MacOS/NotchHub" 2>/dev/null || echo 未知架构)）"
