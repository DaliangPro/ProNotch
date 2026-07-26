import AppKit
import CoreGraphics

/// 键盘上音量/亮度那几颗键的拦截器。
///
/// **为什么非拦不可**：macOS 的音量、亮度提示是 `OSDUIHelper` 弹的，
/// 屏幕正中那块半透明方块。系统没给任何开关关掉它，也没有 API 换个地方画。
/// 只监听不拦截的话，按一下键会同时弹两个提示——屏幕中间一个、刘海里一个，
/// 那不叫「做进刘海里」，那叫多了一个。
///
/// 所以唯一的路是**把按键在到达系统之前吃掉**：事件不到 `OSDUIHelper`，
/// 它就不弹；音量/亮度改由我们自己调（见 `VolumeController` / `BrightnessController`），
/// 提示由刘海来出。这需要辅助功能权限——ProNotch 本来就在用（长截图滚轮、
/// 剪贴板自动粘贴），不是为这个功能新引入的。
///
/// **安全边界**：
/// - 只吃 5 颗键（音量增减静音、亮度增减），播放/上一首/下一首等一律原样放行；
/// - `handler` 返回 false（比如这台设备根本没有音量控制）就放行，交回系统；
/// - 事件 tap 随进程存亡。ProNotch 崩了或退出，tap 自动消失、按键立刻恢复原样，
///   不会把用户的音量键锁死在一个坏掉的状态里。
@MainActor
final class MediaKeyTap {

    enum Key {
        case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

        /// IOKit `ev_keymap.h` 里的 NX_KEYTYPE_* 值。不 import IOKit 私有头，
        /// 就地写死这五个常量——它们是二十年没变过的 ABI
        init?(nxKeyCode: Int32) {
            switch nxKeyCode {
            case 0: self = .volumeUp
            case 1: self = .volumeDown
            case 2: self = .brightnessUp
            case 3: self = .brightnessDown
            case 7: self = .mute
            default: return nil
            }
        }
    }

    /// 返回 true＝已接管（事件被吞，系统 HUD 不弹）；false＝放行交回系统。
    /// `fine` = 按住 ⇧⌥ 的微调档（系统同款四分之一格）
    var handler: ((_ key: Key, _ fine: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// 装上拦截。返回 false＝没装上，几乎总是「没有辅助功能权限」
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14)   // NSSystemDefined：媒体键走这一类，不是 keyDown
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,   // 排在最前，抢在 OSDUIHelper 之前拿到
            options: .defaultTap,         // 非 listenOnly：要能吞
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                // tap 加在主 run loop 上，回调必然在主线程；断言隔离而非再跳一次队列——
                // 跳队列就来不及在本次回调里决定吞不吞了
                return MainActor.assumeIsolated { me.handle(type: type, event: event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            AppLog.systemHUD.error("媒体键拦截装载失败（多半缺辅助功能权限）")
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        AppLog.systemHUD.debug("媒体键拦截已装载")
        return true
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        source = nil
        // 卸载时若正好有键按着，它的抬起事件不会再经过我们了；留着记录只会让
        // 下次装载起手就带着一个陈旧的「这个键我接管过」
        handledKeys.removeAll()
        AppLog.systemHUD.debug("媒体键拦截已卸载")
    }

    deinit {
        // deinit 不在 MainActor 上，不能碰 @MainActor 方法；这里只做最小的失效处理，
        // run loop source 会随 port 失效自然停止投递
        if let port = tap { CFMachPortInvalidate(port) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统会在回调超时或用户输入异常时把 tap 关掉，不重新打开的话按键就永远不再经过我们。
        // 这不是错误路径而是常规路径，必须处理
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            AppLog.systemHUD.debug("媒体键 tap 被系统关闭，已重新启用")
            return Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined,
              ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }

        // data1 高 16 位是键码，低 16 位里第 8~15 位是按下/抬起状态（0xA = 按下）
        let data = ns.data1
        let code = Int32((data & 0xFFFF_0000) >> 16)
        let pressed = ((data & 0xFF00) >> 8) == 0x0A
        guard let key = Key(nxKeyCode: code) else { return Unmanaged.passUnretained(event) }

        // 抬起事件也要一并吃掉：只吃按下的话，抬起那半个事件照样传到系统，
        // OSDUIHelper 收到一个没头没尾的抬起会补弹一次 HUD
        guard pressed else { return handledKeys.contains(key) ? nil : Unmanaged.passUnretained(event) }

        let fine = ns.modifierFlags.contains(.shift) && ns.modifierFlags.contains(.option)
        guard handler?(key, fine) == true else {
            handledKeys.remove(key)
            return Unmanaged.passUnretained(event)
        }
        handledKeys.insert(key)
        return nil   // 吞掉：系统 HUD 不会出现
    }

    /// 按下时接管了哪些键——抬起事件要按同样的决定处理，
    /// 否则「按下被吃、抬起放行」会让系统补弹一次 HUD
    private var handledKeys: Set<Key> = []
}
