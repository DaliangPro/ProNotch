# NotchHub

把 MacBook 的刘海变成快捷启动中心：鼠标悬停刘海自动展开面板，集成 App 快捷启动、剪贴板历史、AI 对话三个功能；鼠标移开自动收回。

## 路线图

- [x] M0 核心交互骨架：刘海定位、悬停展开/收起动画、三标签页框架
- [x] M1 App 启动台：搜索框（输入即时过滤，回车启动第一个结果）+
      置顶槽位区（右键应用图标置顶/取消，默认留空）+ 全部应用滚动网格，
      点击启动并收起面板
- [x] M2 剪贴板历史：0.5s 轮询捕获文本/图片/文件路径，跳过密码管理器
      标记的敏感内容，相同文本去重置顶，保留 50 条并持久化到
      `~/Library/Application Support/NotchHub/Clipboard/`，
      每条带复制/删除按钮（操作后面板保持展开，复制有绿色「已复制」反馈），
      右键也可删除，支持一键清空
- [x] M3 AI 对话：OpenAI 兼容接口（自动规范化端点路径，支持 DeepSeek/
      Kimi/Ollama 等），自填 API 地址 + Key + 模型名（可一键拉取模型列表），
      SSE 流式输出可中途停止，单会话保留上下文（收起不清空、重启清空），
      回复文本可选中复制；联网搜索开关（客户端先搜后答：内置 DuckDuckGo
      免费搜索，选填 Tavily Key 更稳定，回复标注参考结果数）
- [x] 刘海两侧快捷操作：区域截图（自动进剪贴板历史）、系统设置、
      防休眠（caffeinate 开关）、熄屏锁定
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

其他调试通道（同样的发送方式，换通知名）：

- `com.jiliang.NotchHub.snapshot`：把窗口内容渲染成 PNG 存到 `/tmp/notchhub-snapshot.png`
- `com.jiliang.NotchHub.testlaunch`：走真实代码路径启动计算器并收起面板
- `com.jiliang.NotchHub.nexttab`：循环切换标签页
- `com.jiliang.NotchHub.testpaste`：把剪贴板历史第一条回填剪贴板
- `com.jiliang.NotchHub.testchat`：发送一条测试对话消息（需已配置 API；
  联调可用 `/tmp/notchhub-mock-llm.py` 起本地 mock SSE 服务）
- `com.jiliang.NotchHub.testsearch`：执行一次联网搜索（不调大模型），打印结果列表

注意：命令行用 `pbcopy` 测试中文捕获时需带 `LANG=zh_CN.UTF-8`，
否则 C locale 下 `pbcopy` 会把中文丢成空内容（这是测试管道问题，非应用问题）。

## 架构

- 纯 SwiftPM 工程，无 .xcodeproj；`Scripts/build-app.sh` 负责封装 .app
- `NotchGeometry`：刘海定位，跟随主屏——主屏有真实刘海时贴住刘海；外接屏作主屏时在其菜单栏顶部居中模拟热区（高度与菜单栏一致）
- `NotchPanel`：无边框 NSPanel，窗口层级高于菜单栏，全空间可见
- `NotchViewModel`：展开/收起状态机
- `Views/`：SwiftUI 绘制刘海形状（`NotchShape`）与面板内容
- 交互架构：窗口 frame 固定为展开尺寸、永不调整（杜绝位置漂移与
  「窗口缩放和内容动画合帧导致斜向展开」）；收起时 `ignoresMouseEvents = true`
  使透明窗口对鼠标完全隐形（假刘海区域点击穿透到下层菜单栏）；
  悬停检测 = 全局/本地鼠标监听 + 0.2s 轮询兜底，按屏幕坐标判定进出
