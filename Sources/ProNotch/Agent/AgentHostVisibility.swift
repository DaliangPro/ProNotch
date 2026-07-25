import AppKit

/// 宿主 App 是不是「就摊在你眼前」。
///
/// 「前台不打扰」原先只看一件事：宿主 == 最前台 App。这条在终端上够用，在桌面版上太宽了——
/// 授权框长在应用窗口**里面**，窗口被别的窗口压住、或整个被最小化收进程序坞时，
/// 你其实什么也看不见，而卡被这条规则吞掉了（大梁老师报的正是这种「明明没看到」）。
/// 于是再加一道：那扇窗还得真压在最上层。
///
/// 只读 CGWindowList 的归属、层级与边界（不取窗口标题），无需任何权限——与 `FullscreenDetector` 同路。
@MainActor
enum AgentHostVisibility {
    /// 这个 bundle id 的 App 是不是拥有屏上最上层的那扇普通窗口。
    ///
    /// 宿主为空时返回 false：此时「前台不打扰」本来就不生效（见 `AgentWaitStore.present`），
    /// 不必白扫一遍窗口列表
    static func ownsTopWindow(host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        // 按 bundle id 找进程而不是拿最前台那个 PID：同一 App 可能开着多个实例；
        // 而 Electron 类 App 的窗口实测都归主进程（helper 进程另有 bundle id，不会误认）
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: host)
            .map { Int($0.processIdentifier) })
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]] else { return false }
        return ownsTopWindow(pids: pids, in: windows)
    }

    /// 纯判定（可单测）：`windows` 是 CGWindowList 由前到后的顺序，
    /// 取第一扇「普通层、不透明、够大」的窗——那就是此刻压在最上面的真窗口——再看它归谁。
    ///
    /// 三道筛子都不能省：
    /// - `layer == 0` 排掉菜单栏、程序坞、控制中心、悬浮面板与自家刘海窗（层级都在 20 以上）；
    /// - `alpha > 0.1` 排掉留在屏上的透明残窗；
    /// - 尺寸门限排掉 Electron 类 App 常年挂着的细条窗（实测 Claude 桌面版有 2560×30 这种）
    ///   和各类提示气泡：它们在屏上，却不代表「窗口摊在眼前」。
    ///
    /// 一扇合格的窗都没有时返回 false（全最小化 / 都在别的桌面上，那就是看不见），
    /// 这个方向也更安全：判错只是多弹一张卡，反过来是把该弹的卡悄悄吞掉
    nonisolated static func ownsTopWindow(pids: Set<Int>, in windows: [[String: Any]]) -> Bool {
        // 「够大才算一扇真窗」的门限：细条窗与气泡都在这条线以下，正常应用窗都在之上
        let minWidth: CGFloat = 200, minHeight: CGFloat = 120
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.1,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= minWidth, bounds.height >= minHeight,
                  let pid = window[kCGWindowOwnerPID as String] as? Int else { continue }
            return pids.contains(pid)
        }
        return false
    }
}
