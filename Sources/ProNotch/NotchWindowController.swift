import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
    private let env: AppEnvironment
    private let panel: NotchPanel
    /// 两侧功能区设置变更监听 token（close 时移除）
    private var slotObserver: Any?

    /// 数据层由 AppDelegate 持有并传入：换屏重建窗口时对话记录、
    /// 剪贴板监听等状态不丢失
    init(screen: NSScreen, env: AppEnvironment) {
        self.env = env
        let settingsStore = env.settings
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
                .injecting(env))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        // 「全屏时隐藏刘海」：事件驱动（切空间/改设置）+ 每秒兜底重评（Keynote 放映不换
        // 空间，纯事件驱动漏检，靠 poller 兜底）；全屏时整窗隐藏、退出后恢复
        viewModel.shouldHideForFullscreen = { [weak settingsStore] in
            guard settingsStore?.hideNotchInFullscreen == true else { return false }
            // 每块屏只检测自己屏的全屏（外接屏假刘海会遮挡全屏内容）
            return FullscreenDetector.hasFullscreenWindow(on: screen)
        }
        // 两侧功能区开关随设置联动：影响收起态黑条宽度与悬停热区
        viewModel.sideSlotsActive = settingsStore.sideSlotsActive
        slotObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ProNotchSlotSettingsChanged"),
            object: nil, queue: .main) { [weak viewModel, weak settingsStore] _ in
            Task { @MainActor in
                guard let vm = viewModel, let settings = settingsStore else { return }
                vm.sideSlotsActive = settings.sideSlotsActive
            }
        }
        viewModel.startMouseTracking()
        print("[ProNotch] 固定窗口 frame: \(panel.frame)")
    }

    /// 调试用：走与点击图标相同的代码路径启动计算器并收起面板
    func debugTestLaunch() {
        guard let calc = env.launcher.allApps.first(where: {
            $0.url.lastPathComponent == "Calculator.app"
        }) else {
            print("[ProNotch] 调试启动：未找到计算器")
            return
        }
        env.launcher.launch(calc)
        viewModel.collapseNow()
    }

    func close() {
        // 只清理窗口自身的资源；数据层由 AppDelegate 统一管理生命周期
        if let observer = slotObserver {
            NotificationCenter.default.removeObserver(observer)
            slotObserver = nil
        }
        viewModel.stop()
        panel.close()
    }

    /// 调试用：走与「获取模型」按钮相同的路径拉取模型列表（含 UI 状态更新）
    func debugTestModels() {
        env.chat.fetchModels()
    }

    /// 调试用：打印当前屏幕全屏检测结果
    func debugTestFullscreen() {
        let result = FullscreenDetector.hasFullscreenWindow(on: NotchGeometry.targetScreen())
        print("[ProNotch] 全屏检测: \(result ? "有全屏应用" : "无全屏应用")")
    }

    /// 调试用：打印当前外观状态
    func debugTestTheme() {
        env.quickActions.debugProbeAppearance()
    }

    /// 调试用：切换防休眠（配合 pmset -g assertions 验证断言注册）
    func debugTestCaffeinate() {
        env.quickActions.toggleCaffeinate()
    }

    /// 调试用：执行一次联网搜索（不调用大模型），验证搜索链路
    func debugTestSearch() {
        let engine = SearchEngine(rawValue: env.chat.searchEngine) ?? .duckduckgo
        let key: String
        switch engine {
        case .tavily:     key = env.chat.tavilyKey
        case .brave:      key = env.chat.braveKey
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
        guard env.chat.isConfigured else {
            print("[ProNotch] 调试对话：尚未配置 API")
            return
        }
        env.chat.send("有什么能让 Mac 用起来更高效的小技巧？")
    }

    /// 调试用：循环切换标签页（只在当前可见页之间循环，与横滑切页口径一致）
    func debugNextTab() {
        let vis = viewModel.visibleTabs
        guard let index = vis.firstIndex(of: viewModel.activeTab) else { return }
        viewModel.activeTab = vis[(index + 1) % vis.count]
        print("[ProNotch] 切换到标签: \(viewModel.activeTab.title)")
    }

    /// 调试用：把历史第一条复制回剪贴板，验证回填路径
    func debugTestPaste() {
        guard let first = env.clipboard.items.first else {
            print("[ProNotch] 剪贴板历史为空")
            return
        }
        env.clipboard.copyToPasteboard(first)
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
