import Foundation

/// 「更新」这个动作最终会把用户送到某个网址上。这个网址允许长什么样，只由这里说了算。
///
/// 病灶：三条更新来源里有两条把网址的决定权交了出去——
/// jsDelivr CDN 的 `version.json` 里写什么 `url` 就打开什么，
/// GitHub API 的 `html_url` 也是拿来就用。
/// 前者是第三方 CDN 上的一份 JSON，后者虽然可信但没人校验过。
/// 任一环节被换掉，用户点「前往下载」就会被送到别处——而他此刻正准备下载一个要装到系统里的 App。
///
/// 对策：版本号可以由外部告诉我们，网址不行。网址一律由固定仓库拼出来；
/// 外部给的网址只有通过全部三项校验才保留，否则退回官方 releases/latest。
enum ReleaseURLPolicy {
    /// 发版仓库。改这里之前先想清楚：它是整条更新链路唯一的信任锚
    static let repo = "DaliangPro/ProNotch"

    /// 兜底地址：任何校验不过的情况都回到这里
    static var latest: URL {
        URL(string: "https://github.com/\(repo)/releases/latest")!
    }

    /// 按版本号拼出 Release 页地址（tag 命名为 `v<版本号>`）。
    /// 版本号本身也要校验——它同样来自网络，直接塞进 path 就是路径注入
    static func tagURL(forVersion version: String) -> URL {
        guard isPlainVersion(version),
              let url = URL(string: "https://github.com/\(repo)/releases/tag/v\(version)") else {
            return latest
        }
        return url
    }

    /// 外部给的网址：通过校验就保留，否则换成官方 releases/latest
    static func trusted(_ candidate: URL?) -> URL {
        guard let candidate, isTrusted(candidate) else { return latest }
        return candidate
    }

    /// 三项全中才算可信：HTTPS、host 是 github.com、path 在本仓库的 releases 下
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.host?.lowercased() == "github.com" else { return false }
        // https://github.com@evil.com/… 这类 userinfo 障眼法，host 其实已经是 evil.com；
        // 但带 userinfo 的更新地址本身就不正常，一并挡掉
        guard url.user == nil, url.password == nil else { return false }
        return url.path.hasPrefix("/\(repo)/releases/")
    }

    /// 只认「1.2.3」这种纯数字点分版本号
    private static func isPlainVersion(_ version: String) -> Bool {
        guard !version.isEmpty, version.count <= 32 else { return false }
        let segments = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
