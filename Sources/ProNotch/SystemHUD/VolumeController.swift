import CoreAudio
import Foundation

/// 系统输出音量的读写（CoreAudio 公开 API，零权限、零私有符号）。
///
/// 三处坑都是实测踩出来的，不是照抄文档能避开的：
///
/// 1. **默认输出设备不一定有音量**。2026-07-26 在本机实测：默认输出是 LG TV（HDMI），
///    `kAudioDevicePropertyVolumeScalar` 属性**根本不存在**，连静音属性也没有。
///    这种设备上系统自己也调不动（按音量键弹的是那个禁止标志），
///    所以「没有音量控制」是一等状态而非错误——此时我们不接管按键，
///    原样放行让系统去弹它的禁止标志，别让用户以为是 ProNotch 坏了。
///
/// 2. **主音量与逐声道是两套**。不少设备没有 element 0 的主音量，只有左右声道各一份。
///    只查主音量就会把这些设备误判成「没有音量」。
///
/// 3. **默认设备会变**（插拔耳机、切蓝牙）。所以每次都现查设备，不缓存 deviceID——
///    缓存下来拔了耳机还在调耳机那条命的音量。查设备是微秒级的本地调用，不值得缓存。
@MainActor
enum VolumeController {

    /// 一次读数的完整结果
    struct Reading {
        /// 0…1；`available == false` 时无意义
        let volume: Double
        let muted: Bool
        /// 该设备到底能不能调音量（HDMI/TV 常见为 false）
        let available: Bool

        static let unavailable = Reading(volume: 0, muted: false, available: false)
    }

    /// 按一下音量键走多少。macOS 自己是 1/16 格（6.25%），照抄它的手感；
    /// 按住 ⇧⌥ 的微调是 1/4 格（系统同款「四分之一格」细调）
    static let step = 1.0 / 16
    static let fineStep = step / 4

    // MARK: - 读

    static func read() -> Reading {
        guard let dev = defaultOutputDevice() else { return .unavailable }
        guard let volume = readVolume(dev) else { return .unavailable }
        return Reading(volume: volume, muted: readMute(dev) ?? false, available: true)
    }

    // MARK: - 写

    /// 在当前音量上加减一步并返回落定后的读数。
    /// 加减在**读到的真实值**上做，不在我们自己记的值上做——
    /// 中途被别的 App（或控制中心）改过，也不会把音量拽回旧值
    @discardableResult
    static func nudge(by delta: Double) -> Reading {
        let now = read()
        guard now.available else { return .unavailable }
        let target = min(1, max(0, now.volume + delta))
        // 调音量即解除静音（与系统一致：静音时按音量+，是从静音里出来）
        if now.muted, delta > 0 { setMute(false) }
        setVolume(target)
        return Reading(volume: target, muted: target <= 0 ? true : (now.muted && delta <= 0), available: true)
    }

    /// 切换静音并返回落定后的读数
    @discardableResult
    static func toggleMute() -> Reading {
        let now = read()
        guard now.available else { return .unavailable }
        setMute(!now.muted)
        return Reading(volume: now.volume, muted: !now.muted, available: true)
    }

    // MARK: - CoreAudio 细节

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &addr, 0, nil, &size, &id)
        return (st == noErr && id != kAudioObjectUnknown) ? id : nil
    }

    /// 该设备的音量元素：优先主音量（element 0），没有就退回首选立体声两声道。
    /// 返回空数组＝这台设备压根没有音量控制
    private static func volumeElements(_ dev: AudioObjectID) -> [AudioObjectPropertyElement] {
        var master = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &master) { return [kAudioObjectPropertyElementMain] }

        var chans: [UInt32] = [0, 0]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &chans) == noErr else { return [] }
        return chans.filter { ch in
            var a = volumeAddress(ch)
            return AudioObjectHasProperty(dev, &a)
        }
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    /// 逐声道时取各声道的**最大值**当作「当前音量」：与系统音量条的口径一致，
    /// 左右不等（用户拉过平衡）时不会显示成偏小的那一路
    private static func readVolume(_ dev: AudioObjectID) -> Double? {
        let elements = volumeElements(dev)
        guard !elements.isEmpty else { return nil }
        var best: Float32?
        for el in elements {
            var addr = volumeAddress(el)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { continue }
            best = max(best ?? 0, v)
        }
        return best.map(Double.init)
    }

    private static func setVolume(_ value: Double) {
        guard let dev = defaultOutputDevice() else { return }
        for el in volumeElements(dev) {
            var addr = volumeAddress(el)
            guard isSettable(dev, &addr) else { continue }
            var v = Float32(value)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    /// `AudioObjectIsPropertySettable` 的出参是 `DarwinBoolean`，包一层省得每处都摆个临时变量
    /// 再 `.boolValue` 一次。不用共享的 static var 存它：那是块跨调用可写的状态，白担一份风险
    private static func isSettable(_ dev: AudioObjectID,
                                   _ addr: inout AudioObjectPropertyAddress) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func readMute(_ dev: AudioObjectID) -> Bool? {
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr else { return nil }
        return m != 0
    }

    private static func setMute(_ on: Bool) {
        guard let dev = defaultOutputDevice() else { return }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr), isSettable(dev, &addr) else {
            // 没有静音属性的设备（部分 USB / 聚合设备）：把音量压到 0 当静音
            if on { setVolume(0) }
            return
        }
        var v: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }
}
