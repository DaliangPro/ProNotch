import SwiftUI

/// 本机 AI Agent 数据源的统一描述：额度页 / 菜单栏额度栏 / Agent 监控台 / 光晕提醒共用这一份定义。
/// 每家一个总开关（大梁老师定）：勾选即「这家的一切」——能力范围内的额度查询、transcript 扫描、
/// 监控台会话、会话榜一体联动；不勾选则完全不读它的任何文件、不发它的任何请求。
///
/// 各家能力不同（supportsQuota / supportsSessions / supportsGlow），界面按能力诚实渲染：
/// 不支持的能力不显示、不假装。零能力的「仅发现」工具见 `DiscoveredTool`，不进本枚举。
enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case claude, codex, grok, kimi
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .kimi: return "Kimi Code"
        }
    }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        }
    }

    /// 品牌 logo 折线（归一化坐标，BrandIcon 渲染）
    var polys: [[CGPoint]] {
        switch self {
        case .claude: return BrandIconPaths.claude
        case .codex: return BrandIconPaths.openai
        case .grok: return BrandIconPaths.grok
        case .kimi: return BrandIconPaths.kimi
        }
    }

    /// 品牌色（额度页卡片图标 / 菜单栏面板着色共用）
    var tint: Color {
        switch self {
        case .claude: return Color(hex: "#D97757")
        case .codex: return .cyan
        case .grok: return Color(hex: "#8E8E93")
        case .kimi: return Color(hex: "#EDEDED")    // 月之暗面黑白极简，深色 UI 取白
        }
    }

    /// 特征目录：存在即视为已安装（大梁老师定的口径：扫描发现什么，设置里才出现什么）
    var homeDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude")
        case .codex: return home.appendingPathComponent(".codex")
        case .grok: return home.appendingPathComponent(".grok")
        case .kimi: return home.appendingPathComponent(".kimi-code")
        }
    }

    /// 活跃度探测路径：会话/日志目录的 mtime 即「最近用过」的时间
    var activityPath: URL {
        switch self {
        case .claude: return homeDir.appendingPathComponent("projects")
        case .codex: return homeDir.appendingPathComponent("sessions")
        case .grok: return homeDir.appendingPathComponent("logs")
        case .kimi: return homeDir.appendingPathComponent("sessions")
        }
    }

    /// 是否有额度可查（四家全支持；Kimi 走 CLI 内置 managed-usage 同款接口，见 KimiQuotaLoader）
    var supportsQuota: Bool { true }

    /// 是否支持会话监控台——四家全支持。
    /// Grok 一度被判定「无本地会话文件可扫」，那是漏看：只查了 ~/.grok/logs 没进 sessions/，
    /// 实际每个会话一个目录（summary.json + chat_history.jsonl），结构比 Claude 的 jsonl 还规整
    var supportsSessions: Bool { true }

    /// 是否支持光晕完成提醒——四家全有完成钩子可装：Claude Stop 钩子 / Codex notify /
    /// Kimi config.toml [[hooks]] Stop 事件 / Grok hooks 目录独立 JSON（Stop 事件）
    var supportsGlow: Bool { true }

    /// 对应桌面 App 的 bundle id（光晕「切到前台就熄灭」兜底识别用）；
    /// 无桌面版的家为 nil，宿主识别完全依赖 hook 的进程链探测
    var appBundleID: String? {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        default: return nil
        }
    }

    /// 当前勾选集（source of truth 由 SettingsStore 写入；数据层各 Store 刷新时读这里，
    /// 与 SettingsStore 解耦——后台线程扫描前也能安全读取）
    nonisolated static let selectionKey = "enabledAgents"
    nonisolated static func enabledSet() -> Set<AgentKind> {
        guard let raw = UserDefaults.standard.stringArray(forKey: selectionKey) else {
            // 尚未迁移（SettingsStore 首启会写入）：按全开兜底，行为与旧版一致
            return Set(allCases)
        }
        return Set(raw.compactMap(AgentKind.init(rawValue:)))
    }

    /// 见过的家集合（增量默认勾选用）：升级新增的家不在其中 → 检测到即补勾一次，
    /// 之后用户的取消不会被反复覆盖
    nonisolated static let knownKey = "knownAgentKinds"

    /// 升级出新家时的勾选合并（纯函数，便于测试）：
    /// current=现勾选集，known=见过的家，detectedInstalled=本次检测到已安装的家。
    /// 返回 (新勾选集, 新 known)。只有「没见过 且 已安装」的家被补勾——尊重用户对老家的取消。
    nonisolated static func mergeNewlyDetected(
        current: Set<AgentKind>, known: Set<AgentKind>, detectedInstalled: Set<AgentKind>
    ) -> (enabled: Set<AgentKind>, known: Set<AgentKind>) {
        let fresh = Set(allCases).subtracting(known).intersection(detectedInstalled)
        return (current.union(fresh), Set(allCases))
    }
}

/// 一家 Agent 的本机检测结果
struct AgentProbeResult: Identifiable {
    let kind: AgentKind
    let installed: Bool
    let lastActive: Date?
    var id: String { kind.rawValue }
}

/// 本机 Agent 检测：纯 stat / UserDefaults 检查（毫秒级、零副作用），由设置页「扫描」按钮手动触发；
/// 首次启动（无勾选记录时）SettingsStore 也调一次，把检测到的默认勾上——老用户升级无感
enum AgentProbe {
    static func detect() -> [AgentProbeResult] {
        let fm = FileManager.default
        return AgentKind.allCases.map { kind in
            let installed = fm.fileExists(atPath: kind.homeDir.path)
            let lastActive = installed ? (mtime(kind.activityPath) ?? mtime(kind.homeDir)) : nil
            return AgentProbeResult(kind: kind, installed: installed, lastActive: lastActive)
        }
    }

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - 仅发现层：认识但暂无监控能力的本机 AI 工具

/// 检测到但当前零能力（无额度、无监控台、无光晕）的工具——设置页只列出「已发现」，
/// 不给开关、不假装能监控；某家能力打通后升进 `AgentKind`
struct DiscoveredTool: Identifiable {
    let name: String
    let dirLabel: String   // 特征目录的展示写法，如 "~/.gemini"
    let letter: String     // 无品牌折线，字母徽记兜底
    var id: String { name }
}

extension AgentProbe {
    /// 特征库：名称 + 特征目录（相对 home）+ 徽记字母
    private static let knownTools: [(name: String, dir: String, letter: String)] = [
        ("Gemini CLI", ".gemini", "G"),
        ("Factory Droid", ".factory", "D"),
        ("MiniMax Agent", ".minimax-agent", "M"),
        ("OpenCode", ".config/opencode", "O"),
        ("iFlow CLI", ".iflow", "i"),
        ("Qwen Code", ".qwen", "Q"),
        ("ZCode（智谱）", ".zcode", "Z"),
    ]

    /// 只返回本机存在的（未装的不列——零能力家列一排「未发现」没有信息量）
    static func detectTools() -> [DiscoveredTool] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return knownTools.compactMap { t in
            guard fm.fileExists(atPath: home.appendingPathComponent(t.dir).path) else { return nil }
            return DiscoveredTool(name: t.name, dirLabel: "~/\(t.dir)", letter: t.letter)
        }
    }
}
