import AppKit

/// 译文原位排版渲染：拿原图、OCR 出的文字块与对应译文，产出「盖住原文、写上译文」的新图。
///
/// 这一整套是纯计算——输入图与文字块、输出图，不碰选区、工具栏、提示气泡等任何画布状态。
/// 此前它作为 10 个 private static 成员长在 ScreenshotOverlayView 里，被 3000 行的
/// 画布逻辑包着，既看不出它自成一体，也没法单独测：「import NaturalLanguage 该不该翻」
/// 这类判定规则只能靠截图实跑来验，改一条规则要人眼比对一轮。
///
/// 抽出来后判定与排版都可直接单测（见 Tests 的 TranslationRendererTests）。
enum TranslationRenderer {
    /// 产品/品牌/技术名白名单（小写匹配）：全小写写法(deepseek/python)与普通英文词字面无法区分，
    /// 靠白名单兜底保留。正确大小写的产品名(DeepSeek/GitHub/macOS)已被下面的驼峰/全大写规则保留，
    /// 这里主要补全小写与首字母大写写法。遇到漏网的冷门名字往这里加即可。
    nonisolated static let brandKeep: Set<String> = [
        "deepseek", "openai", "chatgpt", "gpt", "anthropic", "claude", "gemini", "copilot", "llama", "mistral",
        "github", "gitlab", "google", "apple", "microsoft", "amazon", "azure", "aws", "nvidia", "intel", "amd",
        "openrouter", "ollama", "docker", "kubernetes", "redis", "nginx", "linux", "ubuntu", "macos", "ios",
        "ipados", "android", "windows", "chrome", "safari", "firefox", "python", "swift", "swiftui", "java",
        "javascript", "typescript", "kotlin", "rust", "golang", "react", "vue", "angular", "nodejs", "deno",
        "npm", "figma", "notion", "slack", "discord", "telegram", "wechat", "xcode", "vscode", "vercel",
    ]

    /// 拉丁片段是否需要翻译。逐词分两类：保留词＝白名单产品名 / 驼峰标识符 / 下划线 / 全大写缩写；
    /// 普通英文词＝其余（单字母 a、I 忽略）。规则：
    /// - 纯普通英文（无保留词）→ 翻（helper、Read a file）；
    /// - 含保留词时，普通词≥2 视为「自然语言句子里嵌了产品名」→ 整句送翻，产品名交翻译引擎按语义保留
    ///   （如 "Here is your GitHub sudo authentication code"）；普通词≤1 视为代码/标识符 → 整体保留
    ///   （如 "import NaturalLanguage"）。
    nonisolated static func latinFragNeedsTranslation(_ frag: String) -> Bool {
        let f = frag.trimmingCharacters(in: .whitespaces)
        guard f.count >= 2 else { return false }
        var plain = 0, reserved = 0
        for word in f.split(separator: " ") {
            let w = String(word)
            if w.count < 2 { continue }                                                  // 单字母(a/I)忽略
            if brandKeep.contains(w.lowercased())                                         // 产品/品牌/技术名
                || w.contains("_")                                                       // snake_case
                || w.range(of: "^[A-Z]{2,}$", options: .regularExpression) != nil        // 全大写缩写/常量
                || Array(w).dropFirst().contains(where: { $0.isUppercase }) {            // 驼峰
                reserved += 1
            } else {
                plain += 1
            }
        }
        return reserved == 0 ? plain >= 1 : plain >= 2
    }

    /// 从块文本里抠出「非目标语言」的待翻片段（位置+原文）。目标是 CJK（中/日/韩）→ 抠拉丁片段
    /// （标识符/英文短语，如 "import NaturalLanguage"、"status=200"），产品名/缩写/代码值按上面规则保留；
    /// 目标是拉丁语言 → 抠连续 CJK 片段。只送这些片段、不送整块——避免中文长句拖慢/中译中被拒。
    nonisolated static func translatableFragments(in text: String, targetIsCJK: Bool) -> [(range: NSRange, text: String)] {
        // 拉丁分支只抠「纯字母词／空格连接的字母短语」（import NaturalLanguage、Read a file、looksTranslatable）；
        // 含数字的代码值/版本号（status=200、v1.6.0）不匹配此模式，天然留在原文——再靠「紧邻的下一字符是数字或 =」
        // 兜掉 status 这种「字母紧贴代码值」的前缀，避免把 status 单独抠去翻成「状态=200」。
        let pattern = targetIsCJK
            ? "[A-Za-z]+(?: [A-Za-z]+)*"
            : "[\\x{4E00}-\\x{9FFF}\\x{3400}-\\x{4DBF}\\x{3040}-\\x{30FF}\\x{AC00}-\\x{D7A3}]+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var result: [(range: NSRange, text: String)] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            if targetIsCJK {                                   // 下一字符是数字或 = → 这是代码值前缀，跳过
                let end = m.range.location + m.range.length
                if end < ns.length {
                    let next = ns.substring(with: NSRange(location: end, length: 1))
                    if next == "=" || next.range(of: "^[0-9]$", options: .regularExpression) != nil { return }
                }
            }
            let frag = ns.substring(with: m.range)
            if !targetIsCJK || latinFragNeedsTranslation(frag) { result.append((range: m.range, text: frag)) }
        }
        return result
    }

    /// 把块内片段按译文就地替换（从后往前，避免前面替换改变后面片段的位置），中文与保留项原样不动
    nonisolated static func applyFragments(_ text: String,
        _ frags: [(range: NSRange, text: String)], _ map: [String: String]) -> String {
        let ms = NSMutableString(string: text)
        for f in frags.reversed() {
            guard let tr = map[f.text], !tr.isEmpty, tr != f.text else { continue }
            ms.replaceCharacters(in: f.range, with: tr)
        }
        return ms as String
    }

    /// 按当前（部分）译文把各块的英文片段就地替换后整体渲染（走主线程，与 renderTranslated 同隔离）
    static func renderFragments(base: CGImage, size: NSSize,
        blocks: [(text: String, box: CGRect)], blockFrags: [[(range: NSRange, text: String)]],
        uniqueList: [String], partial: [String]) -> NSImage {
        var map: [String: String] = [:]
        for (k, t) in uniqueList.enumerated() where k < partial.count && !partial[k].isEmpty { map[t] = partial[k] }
        let full = zip(blocks, blockFrags).map { applyFragments($0.0.text, $0.1, map) }
        return renderTranslated(base: base, size: size, blocks: blocks, translations: full)
    }
    static func renderTranslated(base: CGImage, size: NSSize,
                                         blocks: [(text: String, box: CGRect)], translations: [String]) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSImage(cgImage: base, size: size).draw(in: NSRect(origin: .zero, size: size))   // 原图作底，背景原样保留
        for (i, b) in blocks.enumerated() {
            guard i < translations.count, !translations[i].isEmpty else { continue }
            let rect = NSRect(x: b.box.minX * size.width, y: b.box.minY * size.height,
                              width: b.box.width * size.width, height: b.box.height * size.height)
            let bg = dominantBg(base, b.box)         // 框内众数色＝真实背景，纯色背景下填充块完全融入、不露框
            bg.setFill()
            NSBezierPath(rect: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
            drawFitted(translations[i], in: rect, textColor: textColor(base, b.box, bg: bg))
        }
        img.unlockFocus()
        return img
    }

    static func drawFitted(_ text: String, in rect: NSRect, textColor: NSColor) {
        var fs = max(12, rect.height)                      // 贴合原文高度
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fs), .foregroundColor: textColor]
        let w = (text as NSString).size(withAttributes: attrs).width
        if w > rect.width, w > 0 {
            fs = max(rect.height * 0.62, fs * rect.width / w)   // 太宽才缩，且保底不至于太小
            attrs[.font] = NSFont.systemFont(ofSize: fs)
        }
        let th = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.midY - th / 2), withAttributes: attrs)
    }

    /// 文字框的真实背景色：把框内像素量化做直方图，取出现最多的颜色簇（文字笔画只占少数像素、
    /// 背景占多数，所以众数簇＝背景），再对该簇求真实均值得到精确背景色。
    /// 比采样行间窄缝更稳——不依赖缝里恰好是纯背景，纯色背景下填充块能完全融入、不露框。
    static func dominantBg(_ image: CGImage, _ box: CGRect) -> NSColor {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let px = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H).integral
        let clip = px.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !clip.isNull, let crop = image.cropping(to: clip) else { return .white }
        let gw = max(1, min(72, Int(clip.width))), gh = max(1, min(36, Int(clip.height)))
        var buf = [UInt8](repeating: 0, count: gw * gh * 4)
        guard let ctx = CGContext(data: &buf, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        // 量化到 16 级/通道做直方图，定位背景颜色簇
        var hist = [Int: Int]()
        for i in stride(from: 0, to: buf.count, by: 4) {
            let key = ((Int(buf[i]) >> 4) << 8) | ((Int(buf[i + 1]) >> 4) << 4) | (Int(buf[i + 2]) >> 4)
            hist[key, default: 0] += 1
        }
        guard let best = hist.max(by: { $0.value < $1.value })?.key else { return .white }
        // 对落在众数簇里的像素求真实均值 → 精确背景色
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, n: CGFloat = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let key = ((Int(buf[i]) >> 4) << 8) | ((Int(buf[i + 1]) >> 4) << 4) | (Int(buf[i + 2]) >> 4)
            if key == best { sr += CGFloat(buf[i]); sg += CGFloat(buf[i + 1]); sb += CGFloat(buf[i + 2]); n += 1 }
        }
        guard n > 0 else { return .white }
        return NSColor(red: sr / n / 255, green: sg / n / 255, blue: sb / n / 255, alpha: 1)
    }

    /// 原文字色：读框内像素，取和背景差异大的（文字）像素的平均色；找不到则退回对比色
    static func textColor(_ image: CGImage, _ box: CGRect, bg: NSColor) -> NSColor {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let px = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H).integral
        let clip = px.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !clip.isNull, let crop = image.cropping(to: clip) else { return contrast(bg) }
        let gw = max(1, min(48, Int(clip.width))), gh = max(1, min(20, Int(clip.height)))
        var buf = [UInt8](repeating: 0, count: gw * gh * 4)
        guard let ctx = CGContext(data: &buf, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return contrast(bg) }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        let c = bg.usingColorSpace(.deviceRGB) ?? bg
        let br = c.redComponent, bgreen = c.greenComponent, bb = c.blueComponent
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, cnt: CGFloat = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = CGFloat(buf[i]) / 255, g = CGFloat(buf[i + 1]) / 255, b = CGFloat(buf[i + 2]) / 255
            if abs(r - br) + abs(g - bgreen) + abs(b - bb) > 0.35 { sr += r; sg += g; sb += b; cnt += 1 }
        }
        guard cnt > 0 else { return contrast(bg) }
        return NSColor(red: sr / cnt, green: sg / cnt, blue: sb / cnt, alpha: 1)
    }
    static func contrast(_ bg: NSColor) -> NSColor { bg.luma < 0.5 ? .white : .black }
}

