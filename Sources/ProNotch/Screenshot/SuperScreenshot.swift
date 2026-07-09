import AppKit
import ScreenCaptureKit

/// 超级截图：先用 ScreenCaptureKit 截下光标所在整屏，铺一层压暗覆盖层，
/// 拖拽框选露出原图，松手弹工具栏（框选 / 备注 / 流程 / 存桌面 / 复制）。
@MainActor
final class SuperScreenshotController {
    static let shared = SuperScreenshotController()
    weak var settings: SettingsStore?   // AppDelegate 注入，翻译时惰性读配置
    private var window: ScreenshotOverlayWindow?
    private var busy = false
    private var warmedUp = false

    func capture() {
        guard !busy, window == nil else { return }   // 防重入：覆盖层已在或正在截
        busy = true
        Task {
            defer { busy = false }
            guard let (image, screen) = await Self.grabActiveDisplay() else { return }
            self.present(image, on: screen)
        }
    }

    /// 冷启动预热：ScreenCaptureKit 首次 SCShareableContent.current 要初始化截屏子系统、
    /// 核对权限、枚举窗口，冷启开销几百 ms~1s，导致"截图第一下慢"。启动后台提前跑一次把
    /// 这笔开销挪到开机阶段，用户首次截图即走热路径。失败（如未授权）静默忽略，不触发实际捕获。
    func warmUp() {
        guard !warmedUp else { return }
        warmedUp = true
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.current
            print("[ProNotch] 截图子系统已预热")
        }
    }

    private func present(_ image: CGImage, on screen: NSScreen) {
        // 翻译配置 provider：点「翻译」时才调用（此刻才读钥匙串，不在截图时读）
        let provider: () -> (ScreenshotTranslator.Config, String, String)? = { [weak self] in
            guard let s = self?.settings else { return nil }
            let c = s.resolvedTranslateConfig
            return (.init(baseURL: c.baseURL, apiKey: c.apiKey, model: c.model,
                          parallel: s.translateParallel,
                          useSystemEngine: s.translateEngine == "system"),
                    s.translateTargetLang, s.translatePrompt)
        }
        let win = ScreenshotOverlayWindow(image: image, screen: screen, translateProvider: provider) { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
        }
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 截下光标所在显示器的整屏（像素级，不含光标）
    private static func grabActiveDisplay() async -> (CGImage, NSScreen)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.displayID else { return nil }
        do {
            let content = try await SCShareableContent.current
            guard let scd = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(CGFloat(scd.width) * screen.backingScaleFactor)
            cfg.height = Int(CGFloat(scd.height) * screen.backingScaleFactor)
            cfg.showsCursor = false
            let filter = SCContentFilter(display: scd, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return (image, screen)
        } catch {
            print("[ProNotch] 超级截图捕获失败: \(error.localizedDescription)")
            return nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension NSColor {
    var luma: CGFloat {
        let c = usingColorSpace(.deviceRGB) ?? self
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}
