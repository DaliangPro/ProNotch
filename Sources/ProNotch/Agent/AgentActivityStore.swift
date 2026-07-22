import Foundation
import Combine

/// 「哪家 Agent 此刻正在干活」——供刘海收起态的两侧槽位显示工作状态。
///
/// 纯事件驱动，不轮询：`UserPromptSubmit` 钩子发 `pronotch://busy` 置入，
/// 回合结束的 `pronotch://done` 移出。一个回合恰好两个事件。
///
/// 为什么不复用 `AgentSessionsStore`：那个扫的是 transcript 全库（Codex 走全量
/// enumerator，每个文件还读 64KB 尾巴），而且刘海收起时它压根不扫描——
/// 让它为了两个小槽位常驻跑起来，等于把之前查出来的常驻内存虚高真凶焊死。
///
/// 按「来源 + 会话」记账而不是只按来源：同一家可以同时开好几个会话，
/// 只按来源记的话，任一会话结束就会把整家判成空闲，另外几个还在跑的就被抹掉了。
@MainActor
final class AgentActivityStore: ObservableObject {

    /// 此刻有回合在进行的家。空集 = 全都闲着
    @Published private(set) var working: Set<AgentKind> = []

    /// 崩溃、强杀、或 ProNotch 当时没开着，都会让完成信号丢失，
    /// 状态就永远卡在「工作中」。超过这个时长没等到收尾信号即自行归为空闲。
    ///
    /// 取 30 分钟是因为它只是兜底而非常规路径：正常回合靠 done 回调准确收尾，
    /// 而一轮长任务（派了一堆后台子 Agent 的那种）跑十几分钟很常见，
    /// 阈值太短会把还在干活的家误判成空闲——那比晚点熄灭更糟
    private let staleAfter: TimeInterval

    /// key 为「来源/会话」，value 为这一回合的开始时刻
    private var turns: [String: (kind: AgentKind, since: Date)] = [:]
    private var sweepTimer: Timer?

    /// `staleAfter` 可注入只为测试：真等 30 分钟没法写用例
    init(staleAfter: TimeInterval = 30 * 60) {
        self.staleAfter = staleAfter
        // 设置页取消勾选某家 → 它的钩子随即被卸掉，收工信号再也不会来。
        // 不主动清账的话，那一家会停在最后一次开工的状态上，一直等到超时兜底才熄
        NotificationCenter.default.addObserver(
            forName: .proNotchAgentSelectionChanged,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAgentSelection() }
        }
    }

    deinit { sweepTimer?.invalidate() }

    private func key(_ kind: AgentKind, _ session: String) -> String {
        "\(kind.rawValue)/\(session)"
    }

    /// 收到「开始工作」信号
    func markBusy(_ kind: AgentKind, session: String) {
        turns[key(kind, session)] = (kind, Date())
        refresh()
    }

    /// 收到「回合结束」信号。
    ///
    /// 会话 id 抓不到时（脚本 sed 扑空）退化成「把这一家全部标闲」：
    /// 宁可早熄灭也不要让黄灯一直亮着——亮着不灭是用户唯一会来投诉的失效方式
    func markIdle(_ kind: AgentKind, session: String) {
        if session.isEmpty {
            turns = turns.filter { $0.value.kind != kind }
        } else {
            turns.removeValue(forKey: key(kind, session))
        }
        refresh()
    }

    /// 只留下仍被勾选的家的账
    func applyAgentSelection(_ enabled: Set<AgentKind> = AgentKind.enabledSet()) {
        turns = turns.filter { enabled.contains($0.value.kind) }
        refresh()
    }

    private func refresh() {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        turns = turns.filter { $0.value.since > cutoff }
        let next = Set(turns.values.map(\.kind))
        if next != working { working = next }
        // 有人在跑才挂扫描定时器，全闲下来立刻拆掉——不留空转的心跳
        if turns.isEmpty {
            sweepTimer?.invalidate()
            sweepTimer = nil
        } else if sweepTimer == nil {
            sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }
}
