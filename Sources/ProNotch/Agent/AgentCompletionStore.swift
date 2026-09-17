import Foundation
import Combine

/// 「任务完成」弹窗的一条提醒：完成提醒选「顶部弹窗」时，刘海长出来的那张卡
struct AgentCompletionNotice: Equatable, Identifiable, Sendable {
    let source: AgentKind
    /// Claude 的 session_id / Codex 的 thread-id。空串＝抓不到，仍可弹卡只是点了跳不准
    let session: String
    /// hook 探测到的宿主 App bundle id（终端 / IDE / 桌面版），点卡跳转与切回收卡都靠它
    let host: String?
    /// 项目名（cwd 末段）。抓不到时为空，卡面退一句通用文案
    let project: String
    /// 卡的光晕色（hex）：设置里这家的提醒色，与四周光晕同一份；nil＝品牌色
    let tintHex: String?

    var id: String { "\(source.rawValue)/\(session)" }

    /// 设置页「预览」造出来的那张卡用这个会话名：点它只收卡、不跳转
    static let previewSession = "preview"

    /// 项目名从 hook 传来时是 base64url（无补位）编码的。
    ///
    /// 目录名可以带空格和中文，裸拼进 query 会在 `open` 或 URLComponents 那一关散架；
    /// 而 base64 原生的 `+ / =` 又都是 query 里的敏感字符，所以脚本那边换成了 `- _` 并去掉补位，
    /// 这里补回来再解。解不出就当没有——卡面退化成只显示 Agent 名，不至于整条提醒作废
    static func decodeProject(_ encoded: String) -> String {
        guard !encoded.isEmpty else { return "" }
        var s = encoded.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 任务完成弹窗的状态层：一次只挂一张，新完成的顶掉旧的。
///
/// **一直挂着**（大梁老师 2026-09-16 定）：点它、或切回它所在的 App 才收，
/// 与四周光晕的熄灭口径一致。
///
/// 只存内存不落盘：这是个「此刻」的信号，重启后恢复出来只会误导人
@MainActor
final class AgentCompletionStore: ObservableObject {

    /// 当前挂着的卡。nil＝不弹
    @Published private(set) var notice: AgentCompletionNotice?

    func present(_ notice: AgentCompletionNotice) {
        AppLog.glow.debug("任务完成：挂卡 \(notice.source.rawValue, privacy: .public) 宿主 \(notice.host ?? "-", privacy: .public)")
        self.notice = notice
    }

    /// 点了卡（去处理了）
    func dismiss() {
        notice = nil
    }

    /// 切到某个 App 的最前台：卡若是在等你回这个 App，收起（与光晕熄灭同一口径）。
    ///
    /// 宿主抓空时退到这家桌面版；连桌面版都没有（如 Kimi 且宿主探测失败）就无从知道该等谁，
    /// 切到任意 App 即收——不留一张永远收不掉的卡
    func dismiss(activated bundleID: String) {
        withdraw { notice in
            let targets = [notice.host, notice.source.appBundleID].compactMap { $0 }.filter { !$0.isEmpty }
            return targets.first.map { $0 == bundleID } ?? true
        }
    }

    /// 挂着的卡满足条件就收掉
    func withdraw(where matches: (AgentCompletionNotice) -> Bool) {
        if let current = notice, matches(current) { notice = nil }
    }
}
