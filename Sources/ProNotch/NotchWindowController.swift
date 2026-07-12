import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
    let launcherStore: LauncherStore
    let clipboardStore: ClipboardStore
    let snippetStore: SnippetStore
    let chatStore: ChatStore
    let quickActions: QuickActionsStore
    let captureStore: CaptureStore
    private let panel: NotchPanel

    /// 数据层由 AppDelegate 持有并传入：换屏重建窗口时对话记录、
    /// 剪贴板监听等状态不丢失
    init(screen: NSScreen,
         launcherStore: LauncherStore,
         clipboardStore: ClipboardStore,
         snippetStore: SnippetStore,
         chatStore: ChatStore,
         quickActions: QuickActionsStore,
         captureStore: CaptureStore,
         settingsStore: SettingsStore,
         usageStore: UsageStore,
         agentSessionsStore: AgentSessionsStore) {
        self.launcherStore = launcherStore
        self.clipboardStore = clipboardStore
        self.snippetStore = snippetStore
        self.chatStore = chatStore
        self.quickActions = quickActions
        self.captureStore = captureStore
        let notchRect = NotchGeometry.notchRect(on: screen)
        let hasRealNotch = screen.safeAreaInsets.top > 0
        print("[ProNotch] 屏幕: \(screen.localizedName)，真实刘海: \(hasRealNotch ? "是" : "否（模拟热区）")，刘海区域: \(notchRect)")

        viewModel = NotchViewModel(notchRect: notchRect)
        // 窗口 frame 固定为展开尺寸，永不调整；收起时对鼠标隐形
        panel = NotchPanel(frame: viewModel.windowFrame)
        panel.ignoresMouseEvents = true
        viewModel.panel = panel

        let hosting = NSHostingView(
            rootView: NotchContainerView()
                .environmentObject(viewModel)
                .environmentObject(launcherStore)
                .environmentObject(clipboardStore)
                .environmentObject(snippetStore)
                .environmentObject(chatStore)
                .environmentObject(quickActions)
                .environmentObject(captureStore)
                .environmentObject(settingsStore)
                .environmentObject(usageStore)
                .environmentObject(agentSessionsStore))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        // 「全屏时隐藏刘海」：每秒检测一次，全屏时整窗隐藏、退出后恢复
        viewModel.shouldHideForFullscreen = { [weak settingsStore] in
            guard settingsStore?.hideNotchInFullscreen == true else { return false }
            // 每块屏只检测自己屏的全屏（外接屏假刘海会遮挡全屏内容）
            return FullscreenDetector.hasFullscreenWindow(on: screen)
        }
        viewModel.startMouseTracking()
        print("[ProNotch] 固定窗口 frame: \(panel.frame)")
    }

    /// 调试用：走与点击图标相同的代码路径启动计算器并收起面板
    func debugTestLaunch() {
        guard let calc = launcherStore.allApps.first(where: {
            $0.url.lastPathComponent == "Calculator.app"
        }) else {
            print("[ProNotch] 调试启动：未找到计算器")
            return
        }
        launcherStore.launch(calc)
        viewModel.collapseNow()
    }

    func close() {
        // 只清理窗口自身的资源；数据层由 AppDelegate 统一管理生命周期
        viewModel.stop()
        panel.close()
    }

    /// 调试用：走与「获取模型」按钮相同的路径拉取模型列表（含 UI 状态更新）
    func debugTestModels() {
        chatStore.fetchModels()
    }

    /// 调试用：打印当前屏幕全屏检测结果
    func debugTestFullscreen() {
        let result = FullscreenDetector.hasFullscreenWindow(on: NotchGeometry.targetScreen())
        print("[ProNotch] 全屏检测: \(result ? "有全屏应用" : "无全屏应用")")
    }

    /// 调试用：打印当前外观状态
    func debugTestTheme() {
        quickActions.debugProbeAppearance()
    }

    /// 调试用：切换防休眠（配合 pmset -g assertions 验证断言注册）
    func debugTestCaffeinate() {
        quickActions.toggleCaffeinate()
    }

    /// 调试用：执行一次联网搜索（不调用大模型），验证搜索链路
    func debugTestSearch() {
        let engine = SearchEngine(rawValue: chatStore.searchEngine) ?? .duckduckgo
        let key: String
        switch engine {
        case .tavily:     key = chatStore.tavilyKey
        case .brave:      key = chatStore.braveKey
        case .duckduckgo: key = ""
        }
        Task { @MainActor in
            do {
                let results = try await WebSearch.search(
                    query: "MacBook 刘海 notch 应用", engine: engine, key: key)
                print("[ProNotch] 搜索返回 \(results.count) 条:")
                for result in results {
                    print("  - \(result.title) | 正文 \(result.snippet.count) 字 | \(result.url)")
                }
            } catch {
                print("[ProNotch] 搜索失败: \(error.localizedDescription)")
            }
        }
    }

    /// 调试用：走真实代码路径发送一条对话消息，验证流式输出
    func debugTestChat() {
        guard chatStore.isConfigured else {
            print("[ProNotch] 调试对话：尚未配置 API")
            return
        }
        chatStore.send("有什么能让 Mac 用起来更高效的小技巧？")
    }

    /// 调试用：循环切换标签页
    func debugNextTab() {
        let all = NotchViewModel.Tab.allCases
        guard let index = all.firstIndex(of: viewModel.activeTab) else { return }
        viewModel.activeTab = all[(index + 1) % all.count]
        print("[ProNotch] 切换到标签: \(viewModel.activeTab.title)")
    }

    /// 调试用：把历史第一条复制回剪贴板，验证回填路径
    func debugTestPaste() {
        guard let first = clipboardStore.items.first else {
            print("[ProNotch] 剪贴板历史为空")
            return
        }
        clipboardStore.copyToPasteboard(first)
    }

    /// 调试用：把窗口内容渲染成 PNG 保存到 /tmp，用于无屏幕录制权限时的 UI 验证
    func saveSnapshot() {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("[ProNotch] 快照失败：无法创建位图")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("[ProNotch] 快照失败：PNG 编码失败")
            return
        }
        let path = "/tmp/notchhub-snapshot.png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("[ProNotch] 快照已保存: \(path)，窗口 frame: \(panel.frame)")
        } catch {
            print("[ProNotch] 快照失败: \(error)")
        }
    }
}
