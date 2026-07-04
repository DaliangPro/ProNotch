import Foundation
import SwiftUI

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

    /// 三源级联：任一成功即止。旧版只依赖 api.github.com——该域名在部分网络（尤其国内）
    /// 基本不可达，且未认证限流 60 次/小时/IP（共享出口 IP 极易耗尽）→ 用户检查更新总失败。
    /// ① github.com 重定向：不走 API、无限流、数据实时，主站可达性远好于 api 域名；
    /// ② jsDelivr CDN：读仓库 docs/version.json，国内可达性最好的兜底（CDN 有几小时缓存，够用）；
    /// ③ GitHub API：原逻辑，海外网络最快最全。
    private static func fetchLatest(repo: String) async throws -> Release {
        var lastError: Error?
        do { return try await fetchViaRedirect(repo: repo) } catch { lastError = error }
        do { return try await fetchViaCDN(repo: repo) } catch { lastError = error }
        do { return try await fetchViaAPI(repo: repo) } catch { lastError = error }
        throw NSError(domain: "ProNotch", code: -2, userInfo: [NSLocalizedDescriptionKey:
            "无法连接更新服务（已尝试 3 个来源）。请检查网络后重试，或直接访问 github.com/\(repo)/releases。"
            + (lastError.map { "（\($0.localizedDescription)）" } ?? "")])
    }

    /// ① 请求 releases/latest，GitHub 302 跳转到 /releases/tag/vX.Y.Z——
    /// 跟随后从最终 URL 提取版本号。HEAD 请求，不拉页面正文
    private static func fetchViaRedirect(repo: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        request.timeoutInterval = 6
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let final = response.url, final.path.contains("/releases/tag/") else {
            throw err("重定向解析失败")
        }
        let tag = final.lastPathComponent
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty, version.first?.isNumber == true else { throw err("版本号解析失败") }
        return Release(version: version, url: final)
    }

    /// ② jsDelivr CDN 读仓库 docs/version.json（发版时同步更新该文件）
    private static func fetchViaCDN(repo: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://cdn.jsdelivr.net/gh/\(repo)@main/docs/version.json")!)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String,
              let url = URL(string: (obj["url"] as? String) ?? "https://github.com/\(repo)/releases/latest") else {
            throw err("CDN 版本信息解析失败")
        }
        return Release(version: version, url: url)
    }

    /// ③ GitHub REST API（原逻辑）
    private static func fetchViaAPI(repo: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.timeoutInterval = 6
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw err("GitHub 返回 \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let urlString = obj["html_url"] as? String,
              let url = URL(string: urlString) else {
            throw err("解析 Release 信息失败")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, url: url)
    }

    private static func err(_ m: String) -> NSError {
        NSError(domain: "ProNotch", code: -1, userInfo: [NSLocalizedDescriptionKey: m])
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

/// 检查更新结果窗（系统弹窗同款式：应用图标 + 标题 + 说明 + 「好」按钮，点按钮才关）。
/// 关键差别：非模态——NSAlert.runModal 会接管事件循环，弹着时截图等全局快捷键全部失灵；
/// 本窗是普通浮动窗口，弹着时一切照常，还能被截图分享
struct UpdateAlertView: View {
    let title: String
    let detail: String
    let onOK: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 56, height: 56)
            }
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOK) {
                Text("好").font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 262)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}
