# ProNotch

把 MacBook 的刘海变成你的效率中心：鼠标悬停刘海，自动展开一块面板——App 快捷启动、剪贴板历史、AI 问答、Agent 额度监控，移开鼠标自动收回，不占 Dock、不抢焦点。

外接显示器作主屏时，面板会出现在主屏顶部中间的「模拟刘海」热区，没有刘海的 Mac 也能用。

![ProNotch 在屏幕顶部展开](docs/screenshot-panorama.png)

## 功能

**启动台** — 全部应用网格 + 即时搜索（回车直接启动第一个结果），常用 App 可右键置顶到顶部专属槽位、置顶图标还能拖动排序：

![启动台](docs/screenshot-launcher.png)

**剪贴板** — 自动记录文本 / 图片剪贴历史（密码管理器标记的敏感内容自动跳过），鼠标悬停刘海即可浏览、一键复制 / 删除；内置「话术库」，常用回复一键复制。更进一步，**全局快捷键（默认 ⌥⌘V，可自定义）唤出「剪贴板切换器」**：屏幕中央铺开一排横向大卡片，← → 选择、回车把选中项自动粘贴回你刚才的输入框、Esc 取消；鼠标也顺手——单击选中、双击直接粘贴、右键删除该条，挑历史项全程不费劲：

![剪贴板历史](docs/screenshot-clipboard.png)

![剪贴板切换器](docs/screenshot-clipboard-switcher.png)

**超级截图** — 全局快捷键（可在设置里自定义）或刘海快捷区一键唤起。悬停自动**吸附窗口**（单击整窗选中），或自由框选，随后弹出工具栏：

- **框选高亮**：矩形 / 椭圆框，可选实线 / 虚线、颜色、粗细；开「高亮」即聚光灯效果——框内提亮、框外压暗，一眼锁定重点
- **文字备注**：在图上添加带引导线的文字说明
- **步骤序号**：①②③ 流程标号，把操作步骤讲清楚
- **自由画笔**：手绘勾画，颜色 / 粗细可调
- **马赛克遮挡**：涂抹、框选两种方式，盖住敏感信息
- **原位翻译**：把图里的外文译成目标语言，直接贴回原图位置。默认走 **macOS 系统翻译**——本机离线、毫秒级出结果（需 macOS 15+，语言包在设置里一键下载）；也可切换成自己填的 AI 接口
- **提取文字（OCR）**：识别图中文字（中英日韩等自动检测），可编辑修正、一键复制
- **长截图**：超出一屏的内容自动滚动、逐帧无缝拼接，支持向上 / 向下；鼠标移开即暂停，随时点「停止」收尾；**双击预览可放大检视**拼接质量再决定保存；自动校准「自然滚动/滚轮反转」下的方向
- **贴图钉屏**（新）：把选区（含标注 / 译文）钉成屏幕上的置顶浮窗，参考资料常驻眼前——可拖动、滚轮缩放、右键复制 / 保存，双击或 Esc 关闭，支持同时钉多张
- **截图问 AI**（新）：一键把截图发给 AI 闪问的视觉模型提问（"这图里讲了什么？"），刘海自动展开到闪问、光标就位，打字即问（需接支持视觉的模型）
- **撤销** / **复制到剪贴板** / **保存到桌面**

![超级截图工具栏](docs/screenshot-superscreenshot.png)

**AI 闪问** — 自填任意 OpenAI 兼容接口（DeepSeek / Kimi / Ollama 等均可），流式输出、Markdown 渲染、可拉取模型列表；联网搜索可选 **DuckDuckGo（免费、零配置）/ Tavily / Brave**，各自填 Key、一键测试：

![AI 闪问](docs/screenshot-chat.png)

**Agent 提醒**（新）— 让 Claude Code / Codex 这类 Agent 完成任务时，屏幕四周亮起呼吸光晕提醒你：Claude Code 橙色、Codex 蓝色，颜色与呼吸节奏都可调；切回对应窗口即自动熄灭。在设置里给每个 Agent 一个开关就能接入它的「完成」钩子——跑长任务时人离开，也不会错过它干完活：

![Agent 提醒](docs/screenshot-agent.png)

**Agent 任务监控台**（新）— 刘海「Agent」页把本机所有 Claude Code / Codex 会话收进一张双列监控台：每张卡片显示会话标题、所在项目、实时状态（该你了 / 运行中 / 空闲）、最后一条回复与 token 消耗；Agent 停下等你确认时，卡片橙色呼吸并置顶，点卡片直接跳回它所在的终端 / IDE。多任务并行跑 Agent，谁在干活、谁在等你，一眼全知道：

![Agent 任务监控台](docs/screenshot-agent-center.png)

**额度**（新）— 盯住 Claude Code / Codex / Grok 的订阅用量，不用切浏览器查：刘海「额度」页三张卡片并排，5 小时窗 + 7 天窗的已用百分比、进度条、重置倒计时一目了然，数据直接读本机 CLI 的官方额度接口 / 会话记录（标注「官方数据」）。菜单栏还常驻一个额度栏，标题直接显示三家已用百分比，点开是 tab 式面板（概览 + 分服务详情、原生毛玻璃），随手一瞥就知道还剩多少。

![额度页](docs/screenshot-usage.png)

![菜单栏额度栏](docs/screenshot-usage-menubar.png)

**还有**：**多显示器全覆盖**（新）——每块屏都有独立刘海面板，外接屏 / 扩展屏也能用，插拔显示器自动增减；菜单栏「检查更新」自动提醒新版本（基于 GitHub Releases，发现新版弹通知 + 菜单标记，引导手动下载）；刘海两侧快捷区（超级截图、熄屏锁定、防休眠、macOS 系统外观深浅色切换、右上角 Agent 提醒开关；应用设置入口在菜单栏图标）；标签页和快捷图标都可拖动排序，排第一的标签就是默认页；检测到全屏应用时自动隐藏，不遮挡内容（可在设置关闭）。

## 安装

要求 macOS 14 或更高（Apple Silicon 与 Intel 均支持）。

1. 从 [Releases](../../releases) 下载最新的 `ProNotch-x.y.z.dmg`
2. 打开 DMG，把 ProNotch 拖进「应用程序」
3. **首次打开**：本应用当前未做 Apple 签名公证，系统会提示无法打开。两种解决办法任选：
   - 在「应用程序」里**右键 ProNotch → 打开 → 再点打开**
   - 或在终端执行：`xattr -dr com.apple.quarantine /Applications/ProNotch.app`
4. 启动后菜单栏出现图标，鼠标移到屏幕顶部中间的刘海位置即可展开面板

### 权限说明

按需触发，不用的功能不需要给权限：

| 权限 | 什么时候要 |
|---|---|
| 屏幕录制 | 第一次用「超级截图」 |
| 辅助功能 | 第一次用「长截图」自动滚动，或「剪贴板切换器」回车自动粘贴 |
| 自动化（System Events） | 第一次用「系统外观深浅色切换」 |
| 登录项 | 在设置里打开「开机自启」 |

## 隐私与安全

- 所有数据只存在你的 Mac 本地，应用本身不上传任何内容
- AI 的 API Key 存放在 macOS 钥匙串，不落明文配置文件
- 联网行为：调用你自己填的 AI 接口、联网搜索（DuckDuckGo / Tavily / Brave，按你所选）；以及启动时向 GitHub 查询一次最新版本号（仅版本号，不含任何个人数据）
- 因为是未签名应用，更新版本后首次读取钥匙串可能弹一次确认框，点「允许」即可

## 从源码构建

要求 Xcode 命令行工具（含 Swift 工具链）。纯 SwiftPM 工程，无 .xcodeproj。

```bash
./Scripts/install.sh            # 构建并安装到 /Applications（旧版进废纸篓）
./Scripts/build-app.sh          # 只构建不安装，产物在 build/ProNotch.app
./Scripts/package-dmg.sh        # 通用二进制（arm64 + x86_64）+ 分发 DMG
```

提示：使用前请先退出 boring.notch 等其他刘海应用，避免抢占刘海区域。

## 开发与调试

调试通道只编译进 debug 构建（`swift build` 默认配置），正式 release 版不含。手动触发展开/收起：

```bash
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.daliangpro.ProNotch.toggle"), object: nil, userInfo: nil, deliverImmediately: true)'
```

其他调试通知名（同样的发送方式）：`snapshot`（面板离屏渲染到 /tmp/notchhub-snapshot.png）、`nexttab`、`testlaunch`、`testpaste`、`testchat`、`testmodels`、`testsearch`、`snapsettings` 等，详见 `AppDelegate.swift`。

测试隔离：用参数域覆盖配置，不碰真实数据，例如
`.build/debug/ProNotch -chatBaseURL http://127.0.0.1:8000/v1`。
命令行用 `pbcopy` 测中文需带 `LANG=zh_CN.UTF-8`，否则 C locale 会把中文丢成空。

## 架构要点

- `NotchGeometry`：刘海定位，跟随主屏——有真实刘海贴刘海，否则在菜单栏顶部居中模拟热区
- `NotchPanel`：无边框 NSPanel，层级高于菜单栏、全空间可见、不激活抢焦点
- `NotchViewModel`：展开/收起状态机。窗口 frame 固定为展开尺寸、永不调整（杜绝位置漂移与斜向展开）；收起时 `ignoresMouseEvents = true`，假刘海区域点击穿透到菜单栏；悬停检测 = 全局/本地鼠标监听 + 0.2s 轮询兜底
- 数据层（启动台/剪贴板/话术/对话/额度/Agent 会话/快捷区/设置）全部由 AppDelegate 持有，换屏重建窗口不丢状态
- 全屏检测走空间切换事件驱动（零轮询）；深浅色切换走 System Events 脚本接口

## 版权

Copyright (c) 2026 DaliangPro. All rights reserved.

本项目为专有软件。未经 DaliangPro 事先书面许可，不得使用、复制、修改、分发、
再许可或销售本项目及其源码。详见 [LICENSE](LICENSE)。
