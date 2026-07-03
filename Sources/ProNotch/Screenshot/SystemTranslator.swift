import AppKit
import SwiftUI
import NaturalLanguage
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

    /// 语言对状态："installed"=已装可用；"supported"=支持但语言包未下载；"unsupported"=不支持
    static func pairStatus(sourceCode: String, targetCode: String) async -> String {
        guard #available(macOS 15.0, *) else { return "unsupported" }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: sourceCode),
                                                         to: Locale.Language(identifier: targetCode))
        switch status {
        case .installed:   return "installed"
        case .supported:   return "supported"
        case .unsupported: return "unsupported"
        @unknown default:  return "unsupported"
        }
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
                catch { print("[ProNotch] 语言包下载引导取消/失败: \(error.localizedDescription)") }
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
        // 快速失败：本地探测源语言，语言包没装/语言对不支持就立刻抛错（调用方秒切 AI），不傻等超时
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(texts.joined(separator: " ").prefix(300)))
        if let src = recognizer.dominantLanguage?.rawValue, !targetCode.hasPrefix(src) {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: src),
                                                             to: Locale.Language(identifier: targetCode))
            switch status {
            case .supported:
                throw Self.err("系统翻译语言包未下载（系统设置→通用→语言与地区→翻译语言）")
            case .unsupported:
                throw Self.err("系统翻译不支持该语言对（\(src) → \(targetCode)）")
            default: break
            }
        }
        jobID += 1
        let id = jobID
        // 看门狗：translationTask 因故未触发（语言包待下载等）时不让调用方无限等
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, let job = self.pending, job.id == id else { return }
            self.pending = nil
            job.cont.resume(throwing: Self.err(
                "系统翻译超时——语言包可能未下载（系统设置→通用→语言与地区→翻译语言）"))
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
    fileprivate func run(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        do {
            let requests = job.texts.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)   // 结果与请求同序
            job.cont.resume(returning: responses.map(\.targetText))
        } catch {
            job.cont.resume(throwing: error)
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
