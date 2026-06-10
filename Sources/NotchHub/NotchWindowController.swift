import AppKit
import SwiftUI

@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
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
            rootView: NotchContainerView().environmentObject(viewModel))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        viewModel.startMouseTracking()
        print("[NotchHub] 固定窗口 frame: \(panel.frame)")
    }

    func close() {
        viewModel.stop()
        panel.close()
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
