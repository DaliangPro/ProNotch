import XCTest
@testable import ProNotch

/// 更新链路的终点是「把用户送到某个网址下载一个要装进系统的 App」。
///
/// 病灶：这个网址原先由外部决定——jsDelivr 上的 `version.json` 里写什么 `url`
/// 就打开什么，GitHub API 的 `html_url` 也是拿来就用。第三方 CDN 上的一份 JSON
/// 被换掉，用户点「前往下载」就被送去了别处，而他正准备装一个 App。
final class UpdateURLValidationTests: XCTestCase {

    private let official = "https://github.com/DaliangPro/ProNotch/releases/latest"

    // MARK: - 放行

    func test合法的tag地址原样保留() {
        let tag = URL(string: "https://github.com/DaliangPro/ProNotch/releases/tag/v2.1.2")!
        XCTAssertTrue(ReleaseURLPolicy.isTrusted(tag))
        XCTAssertEqual(ReleaseURLPolicy.trusted(tag), tag)
    }

    func test合法的下载附件地址也保留() {
        let asset = URL(string:
            "https://github.com/DaliangPro/ProNotch/releases/download/v2.1.2/ProNotch.dmg")!
        XCTAssertTrue(ReleaseURLPolicy.isTrusted(asset))
    }

    func test版本号能拼出官方tag地址() {
        XCTAssertEqual(ReleaseURLPolicy.tagURL(forVersion: "2.1.2").absoluteString,
                       "https://github.com/DaliangPro/ProNotch/releases/tag/v2.1.2")
    }

    // MARK: - 拒绝

    func testHTTP被拒() {
        // 明文 HTTP 意味着任何中间人都能改这个下载页
        assertRejected("http://github.com/DaliangPro/ProNotch/releases/latest")
    }

    func test其他域名被拒() {
        assertRejected("https://githubb.com/DaliangPro/ProNotch/releases/latest")
        assertRejected("https://evil.example.com/DaliangPro/ProNotch/releases/latest")
        // 前缀像、其实是别人的域名
        assertRejected("https://github.com.evil.example.com/DaliangPro/ProNotch/releases/latest")
    }

    func test同域名下的其他仓库被拒() {
        assertRejected("https://github.com/Attacker/ProNotch/releases/latest")
        assertRejected("https://github.com/DaliangPro/OtherRepo/releases/latest")
        // 借前缀伪装成本仓库
        assertRejected("https://github.com/DaliangPro/ProNotch-evil/releases/latest")
    }

    func test本仓库但不在releases下的路径被拒() {
        // issues 页可以被任何人写内容，不是发版渠道
        assertRejected("https://github.com/DaliangPro/ProNotch/issues/1")
    }

    func testuserinfo障眼法被拒() {
        // 眼睛看到 github.com，实际去的是 evil.example.com
        assertRejected("https://github.com@evil.example.com/DaliangPro/ProNotch/releases/latest")
    }

    func test非网页协议被拒() {
        assertRejected("file:///Applications/Calculator.app")
        assertRejected("javascript:alert(1)")
    }

    func test空地址退回官方页() {
        XCTAssertEqual(ReleaseURLPolicy.trusted(nil).absoluteString, official)
    }

    // MARK: - 版本号本身也来自网络

    func test畸形版本号不拼进路径_退回官方页() {
        for bogus in ["../../Attacker/evil", "2.1.2/../../..", "latest", "", "v2.1.2",
                      "2.1.2?x=1", "2.1.2#frag", "2 .1"] {
            XCTAssertEqual(ReleaseURLPolicy.tagURL(forVersion: bogus).absoluteString, official,
                           "「\(bogus)」不是纯数字点分版本号，不该出现在 path 里")
        }
    }

    func test超长版本号被拒() {
        XCTAssertEqual(ReleaseURLPolicy.tagURL(forVersion: String(repeating: "1.", count: 40) + "1")
            .absoluteString, official)
    }

    // MARK: - 兜底

    func test兜底地址就是官方releases页() {
        XCTAssertEqual(ReleaseURLPolicy.latest.absoluteString, official)
        XCTAssertTrue(ReleaseURLPolicy.isTrusted(ReleaseURLPolicy.latest),
                      "兜底地址自己必须先过得了自己的校验")
    }

    func testCDN给恶意地址时仍然打开官方页() {
        // 模拟 version.json 被换成 {"version":"9.9.9","url":"https://evil.example.com/x.dmg"}：
        // 新实现连 url 字段都不读，只按版本号自己拼
        let fromCDN = ReleaseURLPolicy.tagURL(forVersion: "9.9.9")
        XCTAssertEqual(fromCDN.absoluteString,
                       "https://github.com/DaliangPro/ProNotch/releases/tag/v9.9.9")
        XCTAssertTrue(ReleaseURLPolicy.isTrusted(fromCDN))

        let malicious = URL(string: "https://evil.example.com/ProNotch.dmg")!
        XCTAssertEqual(ReleaseURLPolicy.trusted(malicious).absoluteString, official,
                       "就算哪天真读了这个字段，也必须被挡在策略外")
    }

    private func assertRejected(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let url = URL(string: string) else { return }   // 连 URL 都构不出来，等同拒绝
        XCTAssertFalse(ReleaseURLPolicy.isTrusted(url), "「\(string)」不该被信任", file: file, line: line)
        XCTAssertEqual(ReleaseURLPolicy.trusted(url).absoluteString, official,
                       "拒绝之后要退回官方页", file: file, line: line)
    }
}
