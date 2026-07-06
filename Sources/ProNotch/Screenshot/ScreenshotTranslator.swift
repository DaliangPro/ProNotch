import Foundation

/// 调 OpenAI 兼容接口批量翻译（JSON 数组进出，保证 N→N 对应）
enum ScreenshotTranslator {
    struct Config {
        var baseURL: String; var apiKey: String; var model: String
        var parallel: Bool = true
        var useSystemEngine: Bool = false   // true=优先系统翻译（失败降级到本 AI 配置）
    }

    /// 分块并行翻译：按字数把条目切成连续块并发请求（上限 5 路）——模型逐 token 串行生成，
    /// 全文一次请求耗时随字数线性涨；并行后总耗时≈最慢一块。哪块先译完先经 onPartial 回传
    /// （渐进渲染用）；疑似未翻译只重试该块；失败块以空串占位（渲染时跳过=保留原文画面）。
    /// 仅当所有块都失败才抛错。
    static func translate(_ texts: [String], to lang: String, prompt: String, config: Config,
                          onPartial: (@Sendable (_ range: Range<Int>, _ chunk: [String], _ done: Int, _ total: Int) -> Void)? = nil) async throws -> [String] {
        // 提示词里的 {lang} 占位替换为目标语言；用户没留 {lang} 时按原样使用
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SettingsStore.defaultTranslatePrompt : prompt
        let system = raw.replacingOccurrences(of: "{lang}", with: lang)
        // 并行开关关闭（接口限流严）或文字少：单请求，无拆分开销
        let ranges = config.parallel ? chunkRanges(texts, budget: 400) : [0..<texts.count]
        guard ranges.count > 1 else {
            let out = try await translateChunk(texts, to: lang, system: system, config: config)
            onPartial?(0..<texts.count, out, 1, 1)
            return out
        }
        var results = [String](repeating: "", count: texts.count)
        var okCount = 0, done = 0
        var firstError: Error?
        await withTaskGroup(of: (Range<Int>, Result<[String], Error>).self) { group in
            var next = 0
            func launchNext() {
                guard next < ranges.count else { return }
                let r = ranges[next]; next += 1
                group.addTask {
                    do { return (r, .success(try await translateChunk(Array(texts[r]), to: lang, system: system, config: config))) }
                    catch { return (r, .failure(error)) }
                }
            }
            for _ in 0..<min(5, ranges.count) { launchNext() }   // 并发上限 5，防接口限流
            for await (r, res) in group {
                launchNext()   // 完成一块补发一块，保持并发水位
                done += 1
                switch res {
                case .success(let out) where out.count == r.count:
                    for (k, i) in r.enumerated() { results[i] = out[k] }
                    okCount += 1
                    onPartial?(r, out, done, ranges.count)
                case .success, .failure:   // 失败或条数错位：该块空占位（渲染跳过=保留原文），只报进度
                    if case .failure(let e) = res, firstError == nil { firstError = e }
                    onPartial?(r, [], done, ranges.count)
                }
            }
        }
        guard okCount > 0 else { throw firstError ?? err("翻译失败") }
        return results
    }

    /// 单块翻译：首轮整块请求 → 逐条核对，把「没回来的 / 原样回传但明显该翻的」单独小批补翻一次。
    /// 旧逻辑「过半未翻才整块重试」兜不住零散漏翻（模型只漏两三条时不达阈值，漏了就漏了）——
    /// 逐条核对后哪怕只漏一条也会补翻；补翻仍原样回传的视为专名/代号，保留不再纠缠。
    private static func translateChunk(_ texts: [String], to lang: String, system: String, config: Config) async throws -> [String] {
        var out = try await request(texts, system: system, temperature: 0.2, config: config)
        // 条数对不上（长输出被截断/丢尾条）：多则裁、少则空串占位，缺的交给下面按条补翻
        if out.count > texts.count { out = Array(out.prefix(texts.count)) }
        while out.count < texts.count { out.append("") }
        let suspects = texts.indices.filter { i in
            let o = out[i].trimmingCharacters(in: .whitespaces)
            return o.isEmpty || (o == texts[i].trimmingCharacters(in: .whitespaces) && looksTranslatable(texts[i]))
        }
        guard !suspects.isEmpty else { return out }
        let harder = system + "\n\nThe previous attempt returned these strings unchanged or dropped them, which is WRONG. "
            + "Translate every remaining non-\(lang) word or phrase into \(lang) now, "
            + "but keep product/brand names, code identifiers, function names, acronyms, code values with digits, URLs and numbers unchanged."
        if let fix = try? await request(suspects.map { texts[$0] }, system: harder, temperature: 0.5, config: config),
           fix.count == suspects.count {
            for (k, i) in suspects.enumerated() {
                let f = fix[k].trimmingCharacters(in: .whitespacesAndNewlines)
                if !f.isEmpty { out[i] = f }
            }
        }
        return out
    }

    /// 这串文字「看起来该被翻译」：含拉丁词、字母占比可观，且不是 URL/路径——
    /// 纯数字、时间、代码符号原样回传是对的，不算漏翻（internal 供测试）
    static func looksTranslatable(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return false }
        let lower = t.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("www.") || lower.hasPrefix("/") || lower.hasPrefix("~/") { return false }
        // 含数字又带代码符号（=、:、/、_、点分版本号）视为代码值/版本号，保留不补翻（如 status=200、v1.6.0）
        let hasDigit = t.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        if hasDigit, t.range(of: "[=:/_.]", options: .regularExpression) != nil { return false }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 3, Double(letters) / Double(t.count) > 0.4 else { return false }
        return t.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil
    }

    /// 按累计字数（约 budget 字符）切成连续区间，至少 1 条/块——块内保持阅读顺序上下文（internal 供测试）
    static func chunkRanges(_ texts: [String], budget: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0, chars = 0
        for (i, t) in texts.enumerated() {
            if i > start, chars + t.count > budget { ranges.append(start..<i); start = i; chars = 0 }
            chars += t.count
        }
        if start < texts.count { ranges.append(start..<texts.count) }
        return ranges
    }

    /// 单次翻译请求：JSON 数组进出，去掉可能的 ``` 包裹，解析成字符串数组
    private static func request(_ texts: [String], system: String, temperature: Double, config: Config) async throws -> [String] {
        guard let url = completionsURL(config.baseURL) else { throw err("接口地址无效") }
        let inputJSON = String(data: try JSONSerialization.data(withJSONObject: texts), encoding: .utf8) ?? "[]"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": config.model, "temperature": temperature,
            "messages": [["role": "system", "content": system], ["role": "user", "content": inputJSON]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw err("接口返回 \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              var content = (msg["content"] as? String) else { throw err("响应解析失败") }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("```") {
            content = content.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let arr = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String] { return arr }
        // 数组前后带解释文字：截取首个 '[' 到最后一个 ']' 再试
        if let l = content.firstIndex(of: "["), let r = content.lastIndex(of: "]"), l < r,
           let arr = try? JSONSerialization.jsonObject(with: Data(String(content[l...r]).utf8)) as? [String] {
            return arr
        }
        // 兜底按行切（截断的 JSON 会走到这）：去掉行首尾的引号和尾逗号，别把 JSON 碎片当译文
        return content.split(separator: "\n", omittingEmptySubsequences: false).map {
            var line = $0.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(",") { line.removeLast() }
            if line.hasPrefix("\""), line.hasSuffix("\""), line.count >= 2 {
                line = String(line.dropFirst().dropLast())
            }
            return line
        }
    }

    private static func completionsURL(_ baseURL: String) -> URL? {
        var raw = baseURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if !raw.hasSuffix("/chat/completions") { raw += raw.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions" }
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }
    private static func err(_ m: String) -> NSError { NSError(domain: "translate", code: 0, userInfo: [NSLocalizedDescriptionKey: m]) }
}
