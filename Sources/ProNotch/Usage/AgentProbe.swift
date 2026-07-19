import SwiftUI

/// 本机 AI Agent 数据源的统一描述：额度页 / 菜单栏额度栏 / Agent 监控台共用这一份定义。
/// 每家一个总开关（大梁老师定）：勾选即「这家的一切」——额度查询、transcript 扫描、
/// 监控台会话、会话榜一体联动；不勾选则完全不读它的任何文件、不发它的任何请求。
enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case claude, codex, grok
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    /// 品牌 logo 折线（归一化坐标，BrandIcon 渲染）
    var polys: [[CGPoint]] {
        switch self {
        case .claude: return BrandIconPaths.claude
        case .codex: return BrandIconPaths.openai
        case .grok: return BrandIconPaths.grok
        }
    }

    /// 品牌色（额度页卡片图标 / 菜单栏面板着色共用）
    var tint: Color {
        switch self {
        case .claude: return Color(hex: "#D97757")
        case .codex: return .cyan
        case .grok: return Color(hex: "#8E8E93")
        }
    }

    /// 特征目录：存在即视为已安装
    var homeDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude")
        case .codex: return home.appendingPathComponent(".codex")
        case .grok: return home.appendingPathComponent(".grok")
        }
    }

    /// 活跃度探测路径：会话/日志目录的 mtime 即「最近用过」的时间
    var activityPath: URL {
        switch self {
        case .claude: return homeDir.appendingPathComponent("projects")
        case .codex: return homeDir.appendingPathComponent("sessions")
        case .grok: return homeDir.appendingPathComponent("logs")
        }
    }

    /// 是否支持会话监控台（Grok CLI 无本地会话文件可扫）
    var supportsSessions: Bool { self != .grok }

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
}

/// 一家 Agent 的本机检测结果
struct AgentProbeResult: Identifiable {
    let kind: AgentKind
    let installed: Bool
    let lastActive: Date?
    var id: String { kind.rawValue }
}

/// 本机 Agent 检测：纯 stat 检查（毫秒级、零副作用），由设置页「扫描」按钮手动触发；
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
