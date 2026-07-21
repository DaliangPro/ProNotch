import AppKit
import SwiftUI
import UserNotifications

/// 可成为 key 的无边框面板：承载「检查更新」结果窗（按钮可点、回车可关）
private final class UpdateAlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 「检查更新」的呈现层：拉取交给 `UpdateChecker`，这里只管把结果变成用户看得见的东西——
/// 结果窗、菜单顶部的「发现新版本」项、系统通知。
///
/// 主动检查与启动时静默检查走同一个 `handle`，区别只在 manual：主动检查必须给回声
/// （哪怕结论是「已是最新」），静默检查则只留菜单标记和一条通知，不打断用户。
@MainActor
final class UpdatePresenter {
    /// 设置页的「关于」区与调试快照都要读它，故对外暴露
    let checker = UpdateChecker()

    private var resultPanel: NSPanel?
    private weak var menuItem: NSMenuItem?      // 菜单顶部「↓ 发现新版本」，默认隐藏
    private weak var separator: NSMenuItem?

    /// 菜单项由 AppDelegate 建好后登记进来：有新版才显形，两者同进同出
    func attachMenu(item: NSMenuItem, separator: NSMenuItem) {
        self.menuItem = item
        self.separator = separator
    }

    /// 启动时静默检查：只发通知 + 菜单标记，不弹窗
    func checkSilently() {
        checker.check { [weak self] release in self?.handle(release, manual: false) }
    }

    @objc func checkManually() {
        checker.check { [weak self] release in self?.handle(release, manual: true) }
    }

    @objc func openLatestRelease() {
        if let url = checker.available?.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(_ release: UpdateChecker.Release?, manual: Bool) {
        refreshMenuItem()
        if let release {
            if manual {
                // 用户主动检查：醒目弹窗提示 +「前往下载」按钮（不再只在菜单里改一行字）
                showResultWindow(
                    title: "发现新版本 \(release.version)",
                    detail: "当前 \(checker.currentVersion)，可更新到 \(release.version)。",
                    actionTitle: "前往下载",
                    action: { [weak self] in self?.openLatestRelease() })
            } else {
                notify(release)   // 启动时静默检查：只发通知 + 菜单标记，不弹窗打扰
            }
        } else if manual {
            // 非模态结果窗：NSAlert.runModal 会接管事件循环，弹着时截图快捷键等全部失灵；
            // 这里用同款式的普通浮动窗口，弹着时一切照常（还能被截图分享）
            if let err = checker.lastError {
                showResultWindow(title: "检查更新失败", detail: err)
            } else {
                showResultWindow(title: "已是最新版本",
                                 detail: "当前 \(checker.currentVersion) 已是最新。")
            }
        }
    }

    /// 系统弹窗同款式的非模态结果窗：屏幕中央偏上，点「好」或回车关闭
    private func showResultWindow(title: String, detail: String,
                                  actionTitle: String? = nil, action: (() -> Void)? = nil) {
        resultPanel?.orderOut(nil)
        let host = NSHostingView(rootView: UpdateAlertView(
            title: title, detail: detail, actionTitle: actionTitle,
            onAction: action.map { act in { [weak self] in
                self?.resultPanel?.orderOut(nil); self?.resultPanel = nil; act()
            } },
            onOK: { [weak self] in
                self?.resultPanel?.orderOut(nil)
                self?.resultPanel = nil
            }))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let panel = UpdateAlertPanel(contentRect: host.frame, styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.contentView = host
        let sf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: sf.midX - size.width / 2,
                                     y: sf.midY - size.height / 2 + sf.height * 0.12))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        resultPanel = panel
    }

    private func refreshMenuItem() {
        if let release = checker.available {
            menuItem?.title = "↓ 发现新版本 \(release.version)"
            menuItem?.isHidden = false
            separator?.isHidden = false
        } else {
            menuItem?.isHidden = true
            separator?.isHidden = true
        }
    }

    private func notify(_ release: UpdateChecker.Release) {
        let version = release.version
        let urlString = release.url.absoluteString
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            // 回调在任意线程：中心实例在闭包内现取（单例），不跨 @Sendable 边界捕获非 Sendable 对象
            let content = UNMutableNotificationContent()
            content.title = "ProNotch 有新版本"
            content.body = "\(version) 可更新，点击前往下载。"
            content.userInfo = ["url": urlString]
            let request = UNNotificationRequest(
                identifier: "pronotch.update.\(version)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
