# NotchHub

把 MacBook 的刘海变成快捷启动中心：鼠标悬停刘海自动展开面板，集成 App 快捷启动、剪贴板历史、AI 对话三个功能；鼠标移开自动收回。

## 路线图

- [x] M0 核心交互骨架：刘海定位、悬停展开/收起动画、三标签页框架
- [ ] M1 App 启动台（主页面）
- [ ] M2 剪贴板历史
- [ ] M3 AI 对话（自定义 API URL + Key，流式输出）
- [ ] M4 打磨：设置面板、开机自启、多显示器、全屏兼容

## 构建与运行

要求：macOS 13+，Xcode 命令行工具（含 Swift 工具链）。

```bash
./Scripts/build-app.sh        # 构建 release 并封装 build/NotchHub.app
open build/NotchHub.app       # 启动（菜单栏出现图标，无 Dock 图标）
```

退出：点击菜单栏图标 → 退出 NotchHub。

注意：测试悬停交互前请先退出 boring.notch 等其他刘海应用，避免两个应用抢占刘海区域。

## 调试

不靠鼠标悬停，手动触发展开/收起（也可用菜单栏图标里的「展开 / 收起（调试）」）：

```bash
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.jiliang.NotchHub.toggle"), object: nil, userInfo: nil, deliverImmediately: true)'
```

## 架构

- 纯 SwiftPM 工程，无 .xcodeproj；`Scripts/build-app.sh` 负责封装 .app
- `NotchGeometry`：刘海定位（无刘海机型自动模拟顶部热区）
- `NotchPanel`：无边框 NSPanel，窗口层级高于菜单栏，全空间可见
- `NotchViewModel`：展开/收起状态机（悬停防抖 + 鼠标位置二次校验）
- `Views/`：SwiftUI 绘制刘海形状（`NotchShape`）与面板内容
- 展开时序：先瞬时放大窗口 → 内容做弹簧动画；收起反之，动画结束后再缩窗口
