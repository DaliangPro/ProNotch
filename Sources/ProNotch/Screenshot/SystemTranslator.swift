import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// 系统翻译（Apple Translation，macOS 15+）：本机离线、整批毫秒级——截图翻译提速的正解。
/// 框架只允许通过 SwiftUI 的 .translationTask 修饰符拿到 TranslationSession，
/// 这里用一个常驻的隐形小窗承载该修饰符，对外暴露 async 批量翻译接口。
enum SystemTranslator {
    /// 运行时支持判定（编译目标 macOS 14，系统翻译 15+ 才有）
    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 设置里的目标语言 → BCP-47 语言码
    static func languageCode(for lang: String) -> String {
        switch lang {
        case "中文":     return "zh-Hans"
        case "English":  return "en"
        case "日本語":    return "ja"
        case "한국어":    return "ko"
        case "Français": return "fr"
        case "Deutsch":  return "de"
        case "Español":  return "es"
        case "Русский":  return "ru"
        default:         return "zh-Hans"
        }
    }

    /// 批量翻译（与输入等长、顺序一致）。语言包未装/语种不支持时抛错，调用方自行降级
    static func translate(_ texts: [String], targetLang: String) async throws -> [String] {
        guard #available(macOS 15.0, *) else {
            throw NSError(domain: "systranslate", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "系统翻译需 macOS 15 或更高"])
        }
        return try await SystemTranslatorCore.shared.translate(texts, targetCode: languageCode(for: targetLang))
    }
}

/// 语言包下载引导（设置页内嵌的 1×1 隐形视图）：把 request 设为 [源码, 目标码] 即触发
/// `prepareTranslation()` —— 系统在承载窗口（设置窗）上弹出官方下载确认框，无需跳系统设置。
struct LanguagePackDownloader: View {
    @Binding var request: [String]?

    var body: some View {
        if #available(macOS 15.0, *) {
            LanguagePackDownloaderCore(request: $request)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct LanguagePackDownloaderCore: View {
    @Binding var request: [String]?
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                do { try await session.prepareTranslation() }   // 弹系统下载确认；已装则直接返回
                catch { AppLog.screenshot.error("语言包下载引导取消/失败: \(LogRedaction.code(error), privacy: .public) \(error.localizedDescription, privacy: .private)") }
                config = nil
                request = nil          // 复位，同时通知设置页刷新安装状态
            }
            .onChange(of: request) { _, new in
                guard let new, new.count == 2 else { return }
                config = TranslationSession.Configuration(source: Locale.Language(identifier: new[0]),
                                                          target: Locale.Language(identifier: new[1]))
            }
    }
}
#endif

#if canImport(Translation)
@available(macOS 15.0, *)
@MainActor
final class SystemTranslatorCore: ObservableObject {
    static let shared = SystemTranslatorCore()

    /// 变更即触发隐形视图上的 translationTask 重新执行（同语言复用 session 配置，invalidate 重跑）
    @Published var config: TranslationSession.Configuration?

    private struct Job { let id: Int; let texts: [String]; let cont: CheckedContinuation<[String], Error> }
    private var pending: Job?
    private var jobID = 0
    private var window: NSWindow?

    func translate(_ texts: [String], targetCode: String) async throws -> [String] {
        ensureWindow()
        guard pending == nil else { throw Self.err("上一次翻译还在进行") }
        // 注：曾在此用 LanguageAvailability().status 做「没装语言包就快速失败」，但该 API 会
        // 无限挂起（中英混杂页面实测直接卡死），且位于看门狗武装之前 → 永久转圈。已移除，
        // 改为直接翻译、由下方 8 秒看门狗统一兜底降级 AI。系统翻译本身对混杂内容不卡（实测 ~200ms）。
        jobID += 1
        let id = jobID
        // 看门狗：translations 对某些内容（如中英混杂）会挂起不返回，或语言包待下载时不触发；
        // 到点统一走 finish 以超时收尾，让调用方降级 AI（不再依赖 pending 未被 run 清空）
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.finish(id: id, .failure(Self.err("系统翻译超时，已改用 AI")))
        }
        return try await withCheckedThrowingContinuation { cont in
            pending = Job(id: id, texts: texts, cont: cont)
            let target = Locale.Language(identifier: targetCode)
            if var c = config, c.target == target {
                c.invalidate()          // 同配置重跑：必须 invalidate 才会再次触发
                config = c
            } else {
                config = TranslationSession.Configuration(source: nil, target: target)   // 源语言自动检测
            }
        }
    }

    /// translationTask 的回调：拿到 session，跑掉当前挂起的批量任务
    /// 统一收尾：按 job id 匹配，只 resume 一次（run 成功/失败、看门狗超时——谁先到谁收尾）。
    /// run 不再提前清 pending，避免 translations 挂起时看门狗因 pending==nil 失灵（永久转圈的根因）
    private func finish(id: Int, _ result: Result<[String], Error>) {
        guard let job = pending, job.id == id else { return }
        pending = nil
        switch result {
        case .success(let v): job.cont.resume(returning: v)
        case .failure(let e): job.cont.resume(throwing: e)
        }
    }

    fileprivate func run(_ session: TranslationSession) async {
        guard let job = pending else { return }
        let id = job.id
        do {
            let requests = job.texts.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)   // 结果与请求同序
            finish(id: id, .success(responses.map(\.targetText)))
        } catch {
            finish(id: id, .failure(error))
        }
    }

    /// 常驻隐形窗：translationTask 需要视图挂在窗口层级里才会驱动
    private func ensureWindow() {
        guard window == nil else { return }
        let host = NSHostingView(rootView: TranslatorHostView(core: self))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.contentView = host
        w.orderFrontRegardless()
        window = w
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "systranslate", code: 0, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

@available(macOS 15.0, *)
private struct TranslatorHostView: View {
    @ObservedObject var core: SystemTranslatorCore

    var body: some View {
        Color.clear
            .translationTask(core.config) { session in
                await core.run(session)
            }
    }
}
#endif
