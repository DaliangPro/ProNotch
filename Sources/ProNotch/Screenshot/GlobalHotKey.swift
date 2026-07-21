import AppKit
import Carbon.HIToolbox

/// 截图快捷键：虚拟键码 + 修饰键 + 显示用字符。存 UserDefaults（Codable）。
struct ScreenshotShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt   // NSEvent.ModifierFlags.rawValue（仅 cmd/opt/ctrl/shift）
    var keyLabel: String      // 录制时取的按键字符（大写），仅显示用

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    /// 人类可读，如「⌃⌥⇧⌘A」（顺序与系统一致）
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    /// 从录制事件构建：要求「至少一个修饰键 + 一个可识别的非修饰键」，否则 nil
    static func from(event: NSEvent) -> ScreenshotShortcut? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty else { return nil }
        let label = labelFor(event)
        guard !label.isEmpty else { return nil }
        return ScreenshotShortcut(keyCode: event.keyCode, modifierFlags: mods.rawValue, keyLabel: label)
    }

    private static func labelFor(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space:      return "Space"
        case kVK_Return:     return "↩"
        case kVK_Tab:        return "⇥"
        case kVK_Delete:     return "⌫"
        case kVK_Escape:     return ""        // Esc 留作「取消录制」，不能当快捷键
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        default:             return (event.charactersIgnoringModifiers ?? "").uppercased()
        }
    }
}

/// 用 Carbon `RegisterEventHotKey` 注册系统级快捷键：无需辅助功能权限、会消费按键
/// （不会同时触发前台 App）。菜单栏 App 触发全局动作的标准做法。
final class GlobalHotKey {
    /// 按下回调（在主线程的 Carbon 事件循环里触发）
    var onTrigger: (() -> Void)?

    private let id: UInt32          // 多个全局热键各用不同 id 注册（截图=1、剪贴板=2…）
    private var hotKeyRef: EventHotKeyRef?

    // 全进程共享：id → 回调。整个进程只装「一个」事件处理器，按事件携带的热键 id 分发。
    // （早前的写法是每个实例各装一个 handler，但它们是同一个 C 函数指针，Carbon 视为同一
    //   handler，后注册的把先注册的覆盖，导致只有最后那个 id 能响应——截图键因此失灵。）
    private static var callbacks: [UInt32: () -> Void] = [:]
    private static var sharedHandlerInstalled = false

    init(id: UInt32 = 1) { self.id = id }

    /// 注册 / 更新快捷键；传 nil 则只注销当前快捷键
    func update(_ shortcut: ScreenshotShortcut?) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        guard let s = shortcut else { Self.callbacks[id] = nil; return }
        Self.installSharedHandler()
        Self.callbacks[id] = { [weak self] in self?.onTrigger?() }

        let hotKeyID = EventHotKeyID(signature: 0x50524E54 /* 'PRNT' */, id: id)
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(s.keyCode),
                                         Self.carbonModifiers(s.modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &newRef)
        if status == noErr {
            hotKeyRef = newRef
        } else {
            AppLog.screenshot.error("快捷键注册失败（可能被占用）id=\(self.id, privacy: .public): \(status, privacy: .public)")
        }
    }

    /// 整个进程只装一个事件处理器：取出事件携带的热键 id，找对应回调执行
    private static func installSharedHandler() {
        guard !sharedHandlerInstalled else { return }
        sharedHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hkID = EventHotKeyID()
                let st = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if st == noErr { GlobalHotKey.callbacks[hkID.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        return c
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        Self.callbacks[id] = nil
    }
}
