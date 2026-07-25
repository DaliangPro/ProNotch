import Foundation

/// 深度思考（`thinking` 字段）兼容层。AI 闪问与截图翻译共用一套判定——两者打的都是
/// OpenAI 兼容的 `/chat/completions`，但只有 DeepSeek v4 这类混合模型认识
/// `thinking:{"type":"disabled"}`，别家看见这个陌生字段会直接 4xx。
///
/// 用户把开关关掉、模型又不支持，这不是用户的错，更不该当成「接口失败」报出来：
/// 摘掉字段原样重发一次即可，只需给一句提醒。重发成功后把这个模型记下来，
/// 之后不再白撞一轮往返（进程内有效，重启即忘——用户换了模型或服务端支持了都能自愈）。
final class ThinkingSupport: @unchecked Sendable {
    static let shared = ThinkingSupport()

    /// 关闭深度思考的请求体字段（DeepSeek 官方取值：enabled / disabled，默认 enabled）
    static let disabledField: [String: Any] = ["type": "disabled"]
    /// 兜底成功后给用户的提醒文案（提醒，不是报错）
    static let notice = "当前模型不支持关闭深度思考，本次已按开启处理"

    private let lock = NSLock()
    private var unsupported = Set<String>()

    /// 这次请求要不要带上 `thinking:{type:disabled}`：用户关了开关、且没记录过该模型不支持
    func shouldSendDisabled(thinkingOn: Bool, baseURL: String, model: String) -> Bool {
        guard !thinkingOn else { return false }
        lock.lock(); defer { lock.unlock() }
        return !unsupported.contains(Self.key(baseURL, model))
    }

    /// 记下「这个模型不认关闭深度思考」。只在摘掉字段重发成功后才调用——
    /// 否则 Key 失效、余额不足这些同为 4xx 的真错因会被误记成不支持
    func markUnsupported(baseURL: String, model: String) {
        lock.lock(); unsupported.insert(Self.key(baseURL, model)); lock.unlock()
    }

    /// 测试用：清空记录，避免用例之间互相污染
    func reset() {
        lock.lock(); unsupported.removeAll(); lock.unlock()
    }

    /// 端点 + 模型才是一个模型的身份：同名模型挂在不同服务商下，能力可能不同
    private static func key(_ baseURL: String, _ model: String) -> String { baseURL + "|" + model }
}
