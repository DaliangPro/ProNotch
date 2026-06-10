#!/bin/bash
# 构建并安装 NotchHub 到 /Applications（日用版与开发目录解耦）
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build-app.sh release

pkill -x NotchHub 2>/dev/null || true
sleep 1

# 旧版本移入废纸篓（不直接删除），再放入新版本
if [ -d "/Applications/NotchHub.app" ]; then
    mv "/Applications/NotchHub.app" ~/.Trash/"NotchHub-旧版-$(date +%Y%m%d%H%M%S).app"
fi
ditto --rsrc "build/NotchHub.app" "/Applications/NotchHub.app"
codesign --force --sign - "/Applications/NotchHub.app" >/dev/null 2>&1 || true

open "/Applications/NotchHub.app"
echo "已安装并启动: /Applications/NotchHub.app"
