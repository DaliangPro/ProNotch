import Foundation

/// 模型的人类可读名（任务书 §10.2.1 / §8.2.5）。
///
/// 界面上原样显示接口 slug（`deepseek-v4-pro`）产品感很差，
/// 但 slug 仍是数据层的唯一标识，不能改——只在展示层做一次映射。
enum ModelDisplayName {

    /// 已知厂商的规范写法。key 一律小写，按最长前缀优先匹配
    private static let brands: [(token: String, name: String)] = [
        ("deepseek", "DeepSeek"),
        ("kimi", "Kimi"),
        ("qwen", "Qwen"),
        ("glm", "GLM"),
        ("gpt", "GPT"),
        ("o3", "o3"),
        ("o4", "o4"),
        ("claude", "Claude"),
        ("gemini", "Gemini"),
        ("grok", "Grok"),
        ("llama", "Llama"),
        ("mistral", "Mistral"),
        ("moonshot", "Moonshot"),
        ("doubao", "豆包"),
        ("ernie", "文心"),
        ("hunyuan", "混元"),
    ]

    /// 常见后缀的规范写法
    private static let suffixes: [String: String] = [
        "pro": "Pro", "max": "Max", "mini": "Mini", "nano": "Nano",
        "flash": "Flash", "turbo": "Turbo", "lite": "Lite", "plus": "Plus",
        "air": "Air", "ultra": "Ultra", "chat": "Chat", "coder": "Coder",
        "reasoner": "Reasoner", "thinking": "Thinking", "instruct": "Instruct",
        "vision": "Vision", "preview": "Preview", "latest": "Latest",
        "sonnet": "Sonnet", "opus": "Opus", "haiku": "Haiku",
    ]

    /// `deepseek-v4-pro` → `DeepSeek V4 Pro`。
    ///
    /// 认不出的段落原样保留（可能是日期或内部代号），只做首字母大写；
    /// 整个 slug 认不出时原样返回——**宁可显示 slug，也不显示猜错的名字**
    static func of(_ slug: String) -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // 有些接口带命名空间（`anthropic/claude-3-5-sonnet`），只取最后一段
        let core = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let parts = core.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard !parts.isEmpty else { return trimmed }

        return parts.map { part -> String in
            let lower = part.lowercased()
            if let brand = brands.first(where: { $0.token == lower })?.name { return brand }
            if let suffix = suffixes[lower] { return suffix }
            // v4 / v1.5 这类版本号：v 大写，数字照抄
            if lower.count >= 2, lower.hasPrefix("v"),
               lower.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
                return "V" + lower.dropFirst()
            }
            // 纯数字（3、20241022）原样
            if lower.allSatisfy(\.isNumber) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }
}
