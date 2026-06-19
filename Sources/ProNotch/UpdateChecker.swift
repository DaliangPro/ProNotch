import Foundation

/// 轻量版本更新检查：访问 GitHub 最新 Release，与当前版本比较。
/// 只做"提醒"，不下载、不安装——发现新版后引导用户去 Releases 页面手动下载。
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release {
        let version: String   // 形如 "1.0.2"
        let url: URL          // Release 页面，供用户下载
    }

    @Published private(set) var available: Release?   // 非 nil = 有比当前更新的版本
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?
    @Published private(set) var checkedUpToDate = false   // 检查过且已是最新（用于"已是最新版"提示）

    /// 仓库 owner/repo（发版时在此发 Release、打版本 tag）
    private let repo = "DaliangPro/ProNotch"

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 检查一次；完成后回调最新可用版本（nil 表示已是最新或失败）。
    func check(completion: ((Release?) -> Void)? = nil) {
        guard !checking else { return }
        checking = true
        lastError = nil
        checkedUpToDate = false
        let current = currentVersion
        let repo = self.repo
        Task { @MainActor in
            do {
                let release = try await Self.fetchLatest(repo: repo)
                self.checking = false
                if Self.isNewer(release.version, than: current) {
                    self.available = release
                    completion?(release)
                } else {
                    self.available = nil
                    self.checkedUpToDate = true
                    completion?(nil)
                }
            } catch {
                self.checking = false
                self.lastError = error.localizedDescription
                completion?(nil)
            }
        }
    }

    private static func fetchLatest(repo: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "ProNotch", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                              "GitHub 返回 \(http.statusCode)（可能尚未发布 Release）"])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let urlString = obj["html_url"] as? String,
              let url = URL(string: urlString) else {
            throw NSError(domain: "ProNotch", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "解析 Release 信息失败"])
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, url: url)
    }

    /// 语义版本号比较：a 是否比 b 新（逐段比较数字，缺位补 0）
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
