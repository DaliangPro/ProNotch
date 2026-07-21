import Foundation

/// 跨模块统一的会话身份：**来源 + 规范化 ID**。
///
/// 病灶：会话 token 表、hook 事件表、宿主映射表原先都以裸字符串为键，且四家的 ID
/// 格式各不相同——
///
/// | 来源   | 会话文件给的 ID                         | hook 事件报回来的 |
/// |--------|-----------------------------------------|-------------------|
/// | Claude | `<uuid>`（transcript 文件名）            | `<uuid>`          |
/// | Codex  | `rollout-<日期>-<uuid>`，聚合根为 `agg-<uuid>` | 裸 `<uuid>`（thread-id）|
/// | Kimi   | `session_<uuid>`（目录名 = session_index 的 sessionId）| `session_id` 字段 |
/// | Grok   | `<uuid>`（会话目录名）                   | 裸 `<uuid>`       |
///
/// 于是匹配只能靠 `s.id == key || s.id.hasSuffix(key)` 这种模糊比对——它既跨不了
/// 来源（Claude 的 uuid 完全可能后缀命中 Codex 的文件名，反之亦然），
/// 也让 `sessionTokens[sessionID]` 在两家撞上同一 UUID 时互相覆盖。
///
/// 对策：ID 只在这一处规范化（取结尾那段 UUID），再和来源打包成一个 Hashable 键。
/// 各模块一律用它，不再各自猜格式。
struct AgentSessionKey: Hashable, Sendable {
    let source: AgentKind
    /// 规范化后的 ID（见 `normalize`）
    let id: String

    init(source: AgentKind, rawID: String) {
        self.source = source
        self.id = Self.normalize(rawID)
    }

    /// 唯一的规范化口径：结尾若是一个合法 UUID 就取它，否则原样保留（去空白、转小写）。
    ///
    /// 这一条规则同时抹平了上表里的四种前缀与 hook 的裸 uuid：
    /// `rollout-2026-07-20T…-<uuid>`、`agg-<uuid>`、`session_<uuid>`、`<uuid>`
    /// 全部收敛到同一个 `<uuid>`
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 36 else { return trimmed.lowercased() }
        let tail = String(trimmed.suffix(36))
        // UUID(uuidString:) 严格校验 8-4-4-4-12 版式，比手写正则可靠
        return (UUID(uuidString: tail) != nil ? tail : trimmed).lowercased()
    }

    // MARK: - 持久化编码

    /// 落 UserDefaults 用的字符串形式（宿主映射要跨重启保留）
    var storageKey: String { "\(source.rawValue)#\(id)" }

    /// 解析 `storageKey`。旧版本存的是不带来源的裸 ID，认不出来就返回 nil——
    /// 这张表只是跳转用的便利缓存，丢了下次 hook 事件就补回来，不值得为它猜来源
    init?(storageKey: String) {
        let parts = storageKey.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let source = AgentKind(rawValue: String(parts[0])),
              !parts[1].isEmpty else { return nil }
        self.init(source: source, rawID: String(parts[1]))
    }
}
