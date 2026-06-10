import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
    let launcherStore = LauncherStore()
    let clipboardStore = ClipboardStore()
    let chatStore = ChatStore()
    private let panel: NotchPanel

    init() {
        let screen = NotchGeometry.targetScreen()
        let notchRect = NotchGeometry.notchRect(on: screen)
        let hasRealNotch = screen.safeAreaInsets.top > 0
        print("[NotchHub] 屏幕: \(screen.localizedName)，真实刘海: \(hasRealNotch ? "是" : "否（模拟热区）")，刘海区域: \(notchRect)")

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
                .environmentObject(chatStore))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        viewModel.startMouseTracking()
        // 启动即预扫描，首次展开面板不用等待
        launcherStore.refreshIfNeeded()
        clipboardStore.startMonitoring()
        print("[NotchHub] 固定窗口 frame: \(panel.frame)")
    }

    /// 调试用：走与点击图标相同的代码路径启动计算器并收起面板
    func debugTestLaunch() {
        guard let calc = launcherStore.allApps.first(where: {
            $0.url.lastPathComponent == "Calculator.app"
        }) else {
            print("[NotchHub] 调试启动：未找到计算器")
            return
        }
        launcherStore.launch(calc)
        viewModel.collapseNow()
    }

    func close() {
        viewModel.stop()
        clipboardStore.stop()
        chatStore.stopStreaming()
        panel.close()
    }

    /// 调试用：走与「获取模型」按钮相同的路径拉取模型列表（含 UI 状态更新）
    func debugTestModels() {
        chatStore.fetchModels()
    }

    /// 调试用：执行一次联网搜索（不调用大模型），验证搜索链路
    func debugTestSearch() {
        let key = chatStore.tavilyKey
        Task { @MainActor in
            do {
                let results = try await WebSearch.search(
                    query: "MacBook 刘海 notch 应用", tavilyKey: key)
                print("[NotchHub] 搜索返回 \(results.count) 条:")
                for result in results {
                    print("  - \(result.title) | \(result.url)")
                }
            } catch {
                print("[NotchHub] 搜索失败: \(error.localizedDescription)")
            }
        }
    }

    /// 调试用：走真实代码路径发送一条对话消息，验证流式输出
    func debugTestChat() {
        guard chatStore.isConfigured else {
            print("[NotchHub] 调试对话：尚未配置 API")
            return
        }
        chatStore.send("联调测试：请用一句话回复")
    }

    /// 调试用：循环切换标签页
    func debugNextTab() {
        let all = NotchViewModel.Tab.allCases
        guard let index = all.firstIndex(of: viewModel.activeTab) else { return }
        viewModel.activeTab = all[(index + 1) % all.count]
        print("[NotchHub] 切换到标签: \(viewModel.activeTab.rawValue)")
    }

    /// 调试用：把历史第一条复制回剪贴板，验证回填路径
    func debugTestPaste() {
        guard let first = clipboardStore.items.first else {
            print("[NotchHub] 剪贴板历史为空")
            return
        }
        clipboardStore.copyToPasteboard(first)
    }

    /// 调试用：把窗口内容渲染成 PNG 保存到 /tmp，用于无屏幕录制权限时的 UI 验证
    func saveSnapshot() {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("[NotchHub] 快照失败：无法创建位图")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("[NotchHub] 快照失败：PNG 编码失败")
            return
        }
        let path = "/tmp/notchhub-snapshot.png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("[NotchHub] 快照已保存: \(path)，窗口 frame: \(panel.frame)")
        } catch {
            print("[NotchHub] 快照失败: \(error)")
        }
    }
}
