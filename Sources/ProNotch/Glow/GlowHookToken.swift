import Foundation

/// `pronotch://done` 回调的认证令牌。
///
/// 病灶：这个 URL scheme 谁都能调。本机上任何进程、任何网页里的一条
/// `<a href="pronotch://done?source=claude&host=com.evil.app&session=…">`，
/// 都能点亮光晕、往会话表里塞一条宿主映射——而宿主映射决定了用户点卡片时跳去哪个 App。
///
/// 对策：安装 hook 时生成一枚高熵令牌，只落在 0600 的文件里，四家脚本都带上它；
/// 应用侧恒定时间比对，对不上就当没收到——不亮光晕，也不动 host/session 映射。
enum GlowHookToken {

    /// 令牌文件与脚本同目录（Application Support/ProNotch），权限 0600
    static func path(_ paths: GlowHookPaths) -> String {
        paths.scriptDir + "/hook-token"
    }

    /// 32 字节随机数的十六进制串。选 hex 是因为它天然 URL 安全，
    /// 拼进 query 不用转义，脚本里也不必操心引号
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // SecRandomCopyBytes 失败极罕见；真失败就退回 UUID，也有 122 bit 熵
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 读现有令牌；没有就生成一个写进去。写不进去返回 nil（调用方据此放弃安装）
    static func ensure(_ paths: GlowHookPaths) -> String? {
        if let existing = current(paths) { return existing }
        let token = generate()
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: paths.scriptDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            // 目录已存在是常态，不算失败；真出问题下面写文件会报出来
        }
        let file = path(paths)
        guard fm.createFile(atPath: file, contents: Data(token.utf8),
                            attributes: [.posixPermissions: 0o600]) else {
            print("[ProNotch] 无法写入 hook 令牌文件")
            return nil
        }
        // createFile 的 attributes 在文件已存在时不生效，补一次
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        return token
    }

    /// 只读，不生成
    static func current(_ paths: GlowHookPaths) -> String? {
        guard let data = FileManager.default.contents(atPath: path(paths)) else { return nil }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

/// 回调放行与否的判定。抽成纯函数，四条分支才都测得到
enum GlowCallbackAuth {

    enum Decision: Equatable {
        case accept
        /// 拒绝理由。**刻意不带令牌值**——日志里出现一次就等于把它公开了
        case reject(String)
    }

    static func decide(token: String?, expected: String?, allowUnsigned: Bool = false) -> Decision {
        guard let expected, !expected.isEmpty else {
            // 本机还没装过 hook：没有令牌可比，谁来的都不认
            return allowUnsigned ? .accept : .reject("本机尚未生成 hook 令牌")
        }
        guard let token, !token.isEmpty else {
            return allowUnsigned ? .accept : .reject("回调缺少令牌")
        }
        return constantTimeEquals(token, expected) ? .accept : .reject("回调令牌不匹配")
    }

    /// 恒定时间比较：逐字节异或累加，不提前返回。
    /// 普通的 `==` 一遇到不同字节就退出，攻击者可以按耗时逐位试出令牌
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        // 长度不同也走完全程，只是结果一定为假；长度本身不是秘密（固定 64 字符）
        var diff = UInt8(lhs.count == rhs.count ? 0 : 1)
        let n = max(lhs.count, rhs.count)
        for i in 0..<n {
            let x = i < lhs.count ? lhs[i] : 0
            let y = i < rhs.count ? rhs[i] : 0
            diff |= x ^ y
        }
        return diff == 0
    }
}
