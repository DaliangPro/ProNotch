#!/bin/bash
# 构建 NotchHub.app：纯 SwiftPM 编译 + 手工封装 bundle（不依赖 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP_DIR="build/NotchHub.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/$CONFIG/NotchHub" "$APP_DIR/Contents/MacOS/NotchHub"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "提示: 临时签名失败，不影响本机运行"
echo "已生成: $APP_DIR"
