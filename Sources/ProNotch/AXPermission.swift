import ApplicationServices

/// 辅助功能权限（长截图合成滚轮、剪贴板切换器自动粘贴共用）：
/// 已授权返回 true；未授权弹一次系统授权引导并返回 false
enum AXPermission {
    static func ensure() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opt)
    }
}
