#!/bin/bash
# 构建 ProNotch.app：纯 SwiftPM 编译 + 手工封装 bundle（不依赖 Xcode 工程）
# 用法: build-app.sh [debug|release] [universal]
#   第二个参数传 universal 时构建 Intel + Apple Silicon 通用二进制（用于分发）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VARIANT="${2:-native}"

# 上一次构建的副本还在跑就别构建。
# 它与 /Applications 版 bundle id 相同（com.daliangpro.ProNotch），于是共享
# UserDefaults、App Support 存档和钥匙串——两个实例互相覆盖设置与剪贴板历史，
# 而 AtomicFileStore 的串行写只在单进程内有效，跨进程管不着。
# 何况下面还要 rm -rf 掉这个 bundle，删正在运行的 App 行为更没准。
#（2026-07-21 实测踩坑：一个副本在后台跑了 10 小时没人发现）
#
# 用 lsof 按文件认而不是 pgrep 按命令行认：进程的命令行取决于当初怎么启动的
#（`open` 给绝对路径、手敲 ./build/… 给相对路径），字符串匹配一换写法就漏。
# 运行中的可执行文件必然被自己的进程持有，按文件问最准。
STALE=$(lsof -t "$PWD/build/ProNotch.app/Contents/MacOS/ProNotch" 2>/dev/null | tr '\n' ' ' || true)
if [ -n "$STALE" ]; then
    echo "❌ 上次构建的 ProNotch 副本还在运行（PID: $STALE）"
    echo "   它和 /Applications 版共享设置、剪贴板历史与钥匙串，会互相覆盖数据。"
    echo "   先停掉再构建：  kill $STALE"
    exit 1
fi

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
