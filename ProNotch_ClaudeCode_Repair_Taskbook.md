# ProNotch 全量代码审查修复执行任务书

> 直接将本文件交给 Claude Code，在 `DaliangPro/ProNotch` 仓库根目录执行。

## 0. 任务身份与最终目标

你正在修复一个纯 SwiftPM 的 macOS 菜单栏应用 ProNotch。

审查基线：

- 仓库：`DaliangPro/ProNotch`
- 分支：`main`
- 基线提交：`283495c788ba654211c61b25005eb6df19b5382b`
- 应用版本：`2.1.2 (55)`
- Swift tools：`5.9`
- 最低系统：`macOS 14`
- 主源码：`Sources/ProNotch`
- 测试：`Tests/ProNotchTests`

目标：修复本任务书列出的安全性、并发一致性、数据可靠性、截图正确性和性能问题，并补齐可以稳定复现这些问题的自动化测试。保持现有产品功能、视觉、快捷键、数据格式和 macOS 14 兼容性。

这是一份实施任务书。不要只输出建议。请直接检查代码、修改代码、补测试、运行验证、按阶段提交。

## 1. 执行规则

1. 开始前运行：

```bash
git status --short
git rev-parse HEAD
swift build
swift test
```

2. 工作区有用户未提交修改时，不覆盖、不回滚、不格式化无关文件。先记录现状，再只修改本任务涉及的文件。

3. 建议创建分支：

```bash
git switch -c fix/review-security-reliability
```

4. 每个修复包独立提交。不要把全部问题揉成一个大提交。

5. 每完成一个修复包，至少运行：

```bash
swift build
swift test
git diff --check
```

6. 最终运行：

```bash
swift build -c release
swift test
./Scripts/build-app.sh
```

`./Scripts/package-dmg.sh` 依赖本机签名环境。签名环境可用时执行；不可用时明确记录跳过原因。

7. 禁止使用 `try?` 吞掉本任务涉及的关键写盘、迁移、配置改写和网络安全错误。错误必须进入可观察状态、日志或用户提示。

8. 不要引入与修复无关的 UI 重做、命名重构、动画调整或产品功能。

9. 默认不增加第三方依赖。确实需要新增依赖时，先证明标准库和小型可测试实现无法满足，并在最终报告说明供应链与许可影响。

10. 新增并发代码时，优先使用 actor、结构化并发和不可变快照。不要用新的 `@unchecked Sendable` 包住可变对象。对 `CGImage` 这类不可变系统对象，可使用边界明确的不可变 Sendable 包装。

11. 所有异步结果在写回当前 UI 状态前，必须验证其请求代际、Provider ID、选中 Agent 集合或截图窗口 ID 仍然有效。

12. 现有测试会操作全局 `UserDefaults`。测试先用普通 `swift test` 顺序执行，除非已完成隔离后再开启并行。

## 2. 全局完成标准

全部任务完成后，必须满足：

- `swift build` 通过。
- `swift build -c release` 通过。
- `swift test` 全绿。
- 现有 106 项左右的测试不减少，新测试覆盖本任务书中的竞态与失败路径。
- `Resources/Info.plist` 不再全局允许任意明文网络访问。
- API Key 迁移失败时，任何旧 Key 都不会被删除。
- 切换 AI Provider 后，旧异步请求不会污染新 Provider，也不会把旧对话发往新端点。
- 非本机 HTTP 端点默认被拒绝。
- 网页正文抓取拒绝内网、环回和链路本地地址，并有重定向复检和响应大小上限。
- Agent Hook 配置改写失败时，用户原配置和现有脚本保持一致、可恢复。
- 快速吸附多个窗口时，导出的图像一定属于当前窗口。
- 长截图停止、取消、预览和最终合成之间没有并发读写，且有明确内存与尺寸上限。
- 写盘失败时截图结果不会被销毁。
- 最终提交历史清楚，每个提交均可构建。

## 3. 推荐提交顺序

建议按以下顺序实施：

1. `fix(security): make keychain migrations transactional`
2. `fix(chat): isolate provider state with immutable request snapshots`
3. `fix(network): enforce secure endpoint and web fetch policies`
4. `fix(chat): use active provider for screenshot translation`
5. `fix(glow): make agent hook updates atomic and conservative`
6. `fix(screenshot): guard window captures by id and generation`
7. `fix(longshot): serialize stitching and enforce resource limits`
8. `fix(stores): reject stale usage and agent refresh results`
9. `fix(storage): serialize persistence and preserve corrupt files`
10. `fix(identity): normalize agent session keys across stores`
11. `fix(clipboard): track switcher selection by stable ids`
12. `fix(reliability): harden weather process update cookie and save paths`
13. `chore(security): authenticate hook callbacks and remove private APIs`

每个提交完成后都运行构建与测试。某一项需要同时改多个模块时，仍保持该提交只解决一个可描述的问题。

# 第一阶段：发布阻断级问题

## P0-01 钥匙串迁移改为事务式迁移

### 涉及文件

- `Sources/ProNotch/Chat/KeychainStore.swift`
- `Sources/ProNotch/Chat/ChatStore.swift`
- `Sources/ProNotch/AppDelegate.swift`
- 可能涉及设置和迁移辅助文件

### 当前风险

`KeychainStore.migrateLegacyService()` 在新 service 写入失败后仍可能删除旧 service 条目。`ChatStore.migrateKeysToKeychainIfNeeded()` 也会在未确认写入成功时删除 `UserDefaults` 中的明文 Key。应用更名迁移最终无条件写入 `didMigrateFromNotchHub`，一次失败后不会再重试。

### 必须实施

1. 给钥匙串访问增加可测试抽象，例如：

```swift
protocol KeychainAccessing: Sendable {
    func read(_ account: String, service: String) -> Result<String?, KeychainError>
    func save(_ value: String, account: String, service: String) -> Result<Void, KeychainError>
    func delete(_ account: String, service: String) -> Result<Void, KeychainError>
}
```

生产实现继续使用 Security framework。现有调用可保留便捷静态入口，但迁移逻辑必须能注入 fake。

2. 每个条目迁移严格执行：

```text
读取旧值
写入新位置
从新位置读回
比较内容一致
删除旧值
```

任一步失败都保留旧值并返回失败。

3. `migrateLegacyService()` 返回结构化结果，至少包含已迁移、无需迁移、失败账户及错误。

4. `migrateKeysToKeychainIfNeeded()` 只有在新钥匙串读回一致后才删除旧 `UserDefaults` 键。

5. `migrateFromNotchHubIfNeeded()` 分步骤记录结果：

- 旧 defaults 域复制
- Application Support 目录迁移
- 钥匙串迁移

只有全部达到“成功或无需迁移”时才设置 `didMigrateFromNotchHub = true`。

6. 目录迁移失败时保留旧目录，不设置完成标记。新目录已存在时不要覆盖。

7. 日志不得打印 Key 内容。

### 必须新增测试

新增 `Tests/ProNotchTests/KeychainMigrationTests.swift`，覆盖：

- 新位置写入失败，旧条目仍存在。
- 新位置读回不一致，旧条目仍存在。
- 删除旧条目失败时返回失败，且新值仍可读取。
- 完整成功后旧值删除、新值存在。
- 重复执行幂等。
- 某一账户失败时迁移完成标记不落盘。
- 明文 `UserDefaults` Key 只在钥匙串校验成功后删除。

### 验收条件

任何错误路径都不能造成 API Key 丢失。失败后下次启动可以继续重试。

## P0-02 AI 多 Provider 使用不可变请求快照并隔离迟到结果

### 涉及文件

- `Sources/ProNotch/Chat/ChatStore.swift`
- 可能新增 `Sources/ProNotch/Chat/ChatRequestConfig.swift`
- 设置页模型拉取和连通检测调用点

### 当前风险

聊天发送只冻结了消息历史，后续搜索、查询改写、非流式补全和流式请求仍读取可变的当前 Provider 字段。用户切换 Provider 后，旧会话可能使用新端点或新 Key。初始钥匙串回填和删除 Provider 后的回填缺少完整的 Provider ID 校验。迟到的连通性和模型列表结果也可能写进当前新 Provider。

### 必须实施

1. 建立不可变且 `Sendable` 的请求快照：

```swift
struct ChatRequestConfig: Sendable, Equatable {
    let providerID: UUID
    let baseURL: String
    let apiKey: String
    let model: String
    let searchEngine: SearchEngine
    let searchKey: String
}
```

2. `send()` 开始时一次性生成快照。下面整个调用链只接收快照，不读取 Store 中实时变化的 Provider 字段：

- `run`
- `rewriteQuery`
- `completeOnce`
- `stream`
- endpoint 规范化
- 搜索引擎与搜索 Key 选择

3. 流式请求继续写回原 `streamingConvID`，保持现有行为。

4. 增加 Provider 代际或请求令牌：

- `activateProvider`
- `addProvider`
- `deleteProvider`
- 保存 Provider 配置

任何会改变当前 Provider 身份或配置的操作都递增 revision。

5. 初始 `loadKeysFromKeychain()` 必须捕获 `providerID`。回主线程时只有当前 ID 仍一致才回填。

6. 删除当前 Provider 后读取下一套 Key 时也要捕获新 Provider ID，并在回填前校验。

7. `checkConnectivity()`、`fetchModels()` 和设置页 API 测试都捕获 Provider ID 与 revision。旧结果迟到时直接丢弃，不更新：

- `connectivity`
- `availableModels`
- `fetchError`
- 当前 Provider 存档

8. 停止流式输出后清理对应请求任务，不影响其他会话。

### 必须新增测试

新增 `ChatProviderIsolationTests.swift`，使用 fake Keychain 和自定义 HTTP transport，覆盖：

- A 的 Key 延迟返回，期间切到 B，A Key 不会写入 B。
- A 发起聊天后切到 B，查询改写、搜索和流式请求全部继续使用 A 的 URL、Key、模型。
- A 的连通性结果在切到 B 后迟到，不改变 B 的状态。
- A 的模型列表迟到，不写入 B。
- 删除 A 后切到 B，A 的旧回填不能覆盖 B。
- 快速连续切换 A、B、C，只有最后一次有效结果落地。

### 验收条件

一次发送从开始到结束始终使用同一份配置。任何异步任务只能更新发起它的 Provider。

## P0-03 收紧 ATS，并统一 API 端点安全策略

### 涉及文件

- `Resources/Info.plist`
- `Sources/ProNotch/Chat/ChatStore.swift`
- `Sources/ProNotch/Screenshot/ScreenshotTranslator.swift`
- 设置页 API 编辑组件
- 建议新增 `Sources/ProNotch/Networking/EndpointPolicy.swift`

### 当前风险

应用全局开启 `NSAllowsArbitraryLoads`。聊天、模型列表和截图翻译只判断 scheme 以 `http` 开头，允许把 Bearer Key、对话和 OCR 文本通过普通 HTTP 发送。

### 必须实施

1. 从 `Info.plist` 删除全局 `NSAllowsArbitraryLoads = true`。

2. 确需支持 Ollama 等本机服务时，只保留最窄的本地网络配置。不要恢复全局任意加载。

3. 建立统一纯函数策略：

```swift
enum EndpointPolicy {
    static func validateUserAPIEndpoint(_ url: URL) throws
}
```

规则：

- `https` 允许。
- `http` 只允许 loopback 主机：`localhost`、`127.0.0.1`、`::1`，大小写和 IPv6 表示需规范化。
- 非本机 HTTP 默认拒绝。
- 缺 host、带用户信息、非法 scheme 拒绝。

4. 以下入口统一调用策略：

- Chat completions endpoint
- `/v1/models`
- ScreenshotTranslator completions endpoint
- 设置页“测试”和“获取模型”

5. 设置页在用户输入不安全端点时给出明确错误，不发送网络请求。

6. README 的本地模型说明如受影响，更新为 HTTPS 或 loopback HTTP 的准确规则。

### 必须新增测试

新增 `EndpointPolicyTests.swift`：

- HTTPS 公网允许。
- `http://localhost`、`127.0.0.1`、`[::1]` 允许。
- `http://example.com` 拒绝。
- `http://192.168.1.2` 默认拒绝。
- `ftp`、`file`、无 host 拒绝。
- ChatStore 与 ScreenshotTranslator 的 URL 生成路径均调用同一策略。

### 验收条件

任何远程 API Key 都不会通过默认普通 HTTP 发送。现有本机 Ollama loopback 用法仍可工作。

## P0-04 WebSearch 防 SSRF、重定向绕过、超大响应和提示词注入

### 涉及文件

- `Sources/ProNotch/Chat/WebSearch.swift`
- `Sources/ProNotch/Chat/ChatStore.swift`
- 建议新增 `Sources/ProNotch/Networking/SafeWebFetcher.swift`

### 当前风险

DuckDuckGo 搜索后会直接抓取前三个结果正文。当前缺少 scheme、私网地址、重定向、内容类型和下载大小限制。抓取到的网页正文会直接注入模型提示词，可能包含恶意指令。

### 必须实施

1. 抽出 `SafeWebFetcher`，支持注入：

- DNS resolver
- URLSession 或 HTTP transport
- 最大响应字节数

2. 抓正文前校验：

- 只允许 `https`。确有兼容要求时，可允许公网 `http`，但不得允许任何私网目标。
- 拒绝 URL 用户信息。
- 拒绝 IP literal 和 DNS 解析结果中的以下范围：loopback、private、link local、carrier grade NAT、multicast、unspecified、IPv6 unique local、IPv6 link local。

3. 每次 HTTP 重定向重新校验目标 URL 和解析地址。目标不安全时取消重定向。

4. 使用流式读取或 URLSession delegate，在下载过程中执行硬上限。建议单页原始响应上限 512 KB，最终提取文本继续遵守现有 `perResultCap`。

5. 只接受 `text/html`、`application/xhtml+xml`、`text/plain`。其他内容类型保留搜索摘要，不抓正文。

6. 设置合理超时，并限制同时抓取数量。

7. `augmentedPrompt` 中明确声明网页内容为不可信数据，模型不得执行其中指令。每个结果用稳定边界包裹，例如：

```text
<search-result index="1" untrusted="true">
...
</search-result>
```

8. 网页抓取失败只能降级使用原搜索摘要，不得阻断聊天。

9. 不要在日志中输出完整网页正文或用户查询。

### 必须新增测试

新增 `SafeWebFetcherTests.swift` 和提示词测试：

- 环回、RFC1918、链路本地、IPv6 本地地址拒绝。
- 公网 HTTPS 允许。
- 公网 URL 302 到内网时拒绝。
- 超过字节上限时停止读取。
- 非文本 Content-Type 不抓取。
- HTML 脚本和样式被清除。
- 搜索提示词包含“不可信数据”约束和边界标签。
- 恶意正文中的“忽略之前指令”只作为数据出现。

### 验收条件

搜索结果不能用于访问本机或局域网服务，不能无上限下载，提示词明确隔离外部网页指令。

## P0-05 截图翻译复用当前活动 Provider

### 涉及文件

- `Sources/ProNotch/Settings/SettingsStore.swift`
- `Sources/ProNotch/Chat/ChatStore.swift`
- `Sources/ProNotch/AppDelegate.swift`
- `Sources/ProNotch/Screenshot/ScreenshotOverlayView.swift`

### 当前风险

开启“与 AI 闪问使用相同 API”时，翻译配置固定读取 `chatAPIKey`，没有使用当前多 Provider 的 `keychainAccount`。第二套及后续配置会出现端点与 Key 错配。

### 必须实施

1. `ChatStore` 暴露当前 Provider 的只读不可变快照，包含：

- providerID
- baseURL
- apiKey
- model

2. `SettingsStore` 不再自行从固定钥匙串账户拼装聊天配置。

3. 截图 overlay 的 `translateProvider` 闭包通过 `AppEnvironment` 同时读取 Settings 和 ChatStore，并在调用瞬间生成一致快照。

4. `translateUseChatAPI == true` 时使用当前活动 Provider 的完整快照。

5. 当前 Provider Key 尚未完成异步回填时，翻译应明确显示“接口尚未就绪”，不能回退到第一套旧 Key。

6. 独立翻译 API 路径继续使用 `translateAPIKey`。

### 必须新增测试

- 两套 Provider 使用不同 URL、Key、模型，切换后翻译配置完全对应当前套。
- 删除第一套后，当前套翻译仍使用正确账号。
- Key 尚未回填时不发送错误请求。

### 验收条件

截图翻译和 AI 闪问当前 Provider 始终一致。

## P0-06 Agent Hook 配置改写原子化、保守化

### 涉及文件

- `Sources/ProNotch/Glow/GlowHookInstaller.swift`
- `Tests/ProNotchTests/GlowHookCommandTests.swift`
- 新增配置 fixture 测试

### 当前风险

Codex TOML 处理只可靠支持单行 `notify = [...]`。合法多行数组可能被部分替换并留下残行。Kimi Hook 删除通过字符串搜索定位，遇到异常格式时可能删除过大范围。脚本与配置的更新顺序也可能在失败后留下互相不一致的状态。

### 必须实施

1. 建立统一原子写入辅助：

- 在同目录写临时文件。
- 保留原文件权限。
- 对新内容执行结构校验。
- 使用原子 replace。
- 失败时删除临时文件，原文件保持字节不变。
- 修改前生成带时间戳或固定轮换策略的备份。

2. Codex 顶层 `notify` 解析支持：

- 单行数组。
- 多行数组。
- 字符串内括号和转义。
- 行注释。
- 只匹配真正的顶层 `notify =`。
- 删除或替换时覆盖整个值范围。

3. 保留现有 previous notify 转发语义。不得把包含 ProNotch 自身的链保存为 previous，继续防止自引用死循环。

4. Kimi 新写入块增加明确边界标记：

```text
# >>> ProNotch managed hook BEGIN
...
# <<< ProNotch managed hook END
```

5. 卸载优先按边界标记删除。对旧版本无边界块，只在能够唯一识别 `[[hooks]]` 表且 command 精确引用 ProNotch 脚本时删除。无法唯一识别时返回失败并保持原文件。

6. 配置成功替换后再删除旧脚本。安装时脚本先写临时文件，配置替换成功后再将脚本原子落位。

7. Claude、Codex、Kimi、Grok 四家的写入和卸载都使用同一套失败一致性原则。

8. 备份与脚本权限要收紧，不要让其他用户可写。

### 必须新增测试

新增 `GlowHookInstallerConfigTests.swift`，fixture 覆盖：

- Codex 单行 notify。
- Codex 多行 notify。
- 注释和字符串中出现 `notify =` 不误命中。
- 当前链直接引用 ProNotch。
- 当前链由其他工具包裹并间接引用 ProNotch。
- 自引用 previous 被拒绝。
- Kimi 新边界块安装、升级、卸载。
- Kimi 旧裸路径块迁移。
- 文件含多个无关 Hook 时全部保留。
- 配置损坏或识别不唯一时文件字节不变。
- 模拟写入失败时脚本和配置不出现半完成状态。

### 验收条件

任何失败都不能损坏用户原有 Claude、Codex、Kimi 或 Grok 配置。成功操作可重复执行且幂等。

## P0-07 窗口吸附截图增加窗口 ID 与 generation 校验

### 涉及文件

- `Sources/ProNotch/Screenshot/ScreenshotOverlayView.swift`
- 建议抽出可测试的小型协调器

### 当前风险

吸附窗口 A 后异步捕获其透明圆角图。用户快速切到窗口 B 时，A 如果最后返回，会覆盖 B 的 `snappedWindowImage`。导出只判断图像非空，没有确认图像属于当前窗口，可能导出错误窗口内容。

### 必须实施

1. 将捕获结果与身份绑定：

```swift
struct CapturedWindowShape {
    let windowID: CGWindowID
    let generation: UInt64
    let image: CGImage
}
```

2. 每次开始新的窗口吸附：

- 递增 generation。
- 取消旧 capture task。
- 清空旧 shape。
- 记录当前 windowID。

3. 异步结果回主线程时同时校验：

- generation 仍一致。
- windowID 仍等于当前 `snappedWindowID`。
- overlay 尚未关闭。

4. `ensureWindowShape()` 不能只检查图像非空，还要检查图像的 ID 和 generation 与当前选择一致。失配时重新捕获。

5. 自由框选、重新选区、关闭 overlay 时取消旧任务并失效 generation。

6. 最终 `compose()` 只有在 shape 的 ID 与当前窗口完全一致时使用独立窗口图。

### 必须新增测试

抽出 coordinator 或使用可控 capture closure：

- A 先开始，B 后开始，B 先完成、A 后完成，最终必须保留 B。
- A 完成后切 B，导出前必须重新捕获 B。
- 关闭 overlay 后迟到结果被忽略。
- 自由框选后旧窗口 shape 不再被使用。

### 验收条件

快速移动和点击多个窗口时，导出内容一定来自当前选中的窗口。

## P0-08 长截图串行化并设置资源上限

### 涉及文件

- `Sources/ProNotch/Screenshot/LongShot.swift`
- `Sources/ProNotch/Screenshot/ScreenshotOverlayView.swift`
- `Tests/ProNotchTests/LongShotStitcherTests.swift`

### 当前风险

`LongShotStitcher` 使用 `@unchecked Sendable`，内部却有可变段数组和灰度缓存。帧拼接在 detached task 中执行，用户点击停止或预览时可能同时调用 `result()`。最终合成按完整尺寸一次分配 RGB buffer，没有高度、像素、时长或帧数上限。

### 必须实施

1. 移除可变 stitcher 上的 `@unchecked Sendable`。

2. 将 stitcher 变为 actor，或让所有访问严格经过单一串行执行器。actor 为首选。

3. 所有方法串行：

- `addFrame`
- `prependFrame`
- `addHead`
- `addTail`
- `probeDirection`
- `previewImage`
- `result`
- `totalHeight`

4. overlay 持有明确任务句柄：

- 主长截图任务
- 连续滚动任务
- 当前帧处理任务
- 最终合成任务

5. “停止”流程：

```text
停止继续滚动和采集
等待或取消当前帧处理
确保 stitcher 内无在途修改
后台生成最终结果
回主线程展示结果
```

6. “取消”流程取消所有任务，并保证迟到结果不会重新打开结果面板。

7. 去掉固定 sleep 250ms 猜测在途帧完成的逻辑，改为等待真实任务或 actor 队列。

8. 加资源上限，至少包含：

- 最大最终像素数，建议以 256 MB 原始 RGBA buffer 为默认安全预算计算。
- 最大高度。
- 最大段数或帧数。
- 最大录制时长。

上限需要集中定义并有注释。达到上限时自动安全收尾，向用户说明“已达到安全上限”。

9. 新增段之前先计算加入后总量。不要等最终 `CGContext` 分配时才失败。

10. 最终 `result()` 和 PNG 编码均在后台执行，不阻塞主线程。

11. 预览生成节流，避免随高度增长不断占用大量 CPU。

12. 如果 `CGImage` 的 Sendable 检查阻塞 actor 边界，只对不可变 `CGImage` 建立小型不可变包装，不要给 stitcher 本身增加 unchecked。

### 必须新增测试

将现有 `LongShotStitcherTests` 改为 async 或 actor 适配，并新增：

- `addFrame` 与 `result` 同时触发时结果一致，无数据竞争。
- 停止时等待最后一帧落定。
- 取消后迟到帧不进入结果。
- 达到像素上限时返回明确状态，不继续增长。
- 达到帧数或时长上限时安全结束。
- 坏帧测试、向上向下拼接测试继续全绿。

### 验收条件

Thread Sanitizer 不出现 stitcher 数据竞争。超长页面不会无限增长到系统内存耗尽。停止按钮得到确定性结果。

# 第二阶段：高优先级一致性与可靠性问题

## P1-09 UsageStore 与 AgentSessionsStore 拒绝旧刷新结果

### 涉及文件

- `Sources/ProNotch/Usage/UsageStore.swift`
- `Sources/ProNotch/Agent/AgentSessionsStore.swift`

### 必须实施

1. 两个 Store 都增加 refresh task 和 generation。

2. Agent 选择变化时：

- 递增 generation。
- 取消旧 task。
- 清除已取消 Agent 的当前数据。
- 立即启动新的强制刷新。

3. 后台结果回主线程前校验 generation 和 enabled Agent 快照。旧结果丢弃。

4. 强制刷新在已有刷新期间到达时，不能直接消失。选择下面一种明确策略：

- 取消旧任务并重启。
- 设置 `pendingForceRefresh`，旧任务结束后立即再跑。

5. 刷新失败和取消都必须正确复位 `refreshing`。

### 测试

使用可延迟 loader：

- A、B 正在刷新时取消 B，旧结果回来后 B 仍为空。
- 刷新中再次 force，最终发布第二次结果。
- 快速切换选择集，只发布最后 generation。
- 取消任务后 `refreshing` 恢复。

## P1-10 聊天、剪贴板和话术持久化串行化

### 涉及文件

- `Sources/ProNotch/Chat/ChatStore.swift`
- `Sources/ProNotch/Clipboard/ClipboardStore.swift`
- SnippetStore 所在文件
- 建议新增 `Sources/ProNotch/Persistence/AtomicFileStore.swift`

### 必须实施

1. 建立 actor 形式的原子文件写入层。

2. ChatStore 每次保存生成单调递增 revision。持久层拒绝比已写 revision 更旧的快照，避免旧 detached task 后完成并覆盖新状态。

3. 所有 JSON 索引使用原子写入。

4. 写入失败必须记录错误，Store 保留可重试状态。

5. 加载遇到损坏 JSON 时：

- 不直接覆盖损坏文件。
- 重命名为 `.corrupt-时间戳`。
- 有备份时尝试恢复。
- 无备份时创建新空数据并记录可见错误。

6. Clipboard 图片文件与索引更新要保持顺序。索引成功后再删除被淘汰文件，或提供可恢复清理策略。

### 测试

- revision 2 先写完，revision 1 后到，最终文件仍是 revision 2。
- 模拟写入中断，旧文件仍可读取。
- 损坏文件被保留并建立新文件。
- 连续快速保存最终内容正确。

## P1-11 Agent 会话键统一包含来源与规范化 ID

### 涉及文件

- `Sources/ProNotch/Usage/UsageStore.swift`
- SessionUsage 所在文件
- `Sources/ProNotch/Agent/AgentSessionsStore.swift`
- Agent 页面 token 关联调用点

### 必须实施

1. 定义：

```swift
struct AgentSessionKey: Hashable, Sendable {
    let source: AgentKind
    let id: String
}
```

2. Kimi ID 统一规范。确认 `session_index.jsonl` 的 `sessionId` 和目录名 `session_<uuid>` 的真实格式，建立单一 normalizer。不要在不同模块各自猜测。

3. `sessionTokens` 从 `[String: Int]` 改为 `[AgentSessionKey: Int]`，防止不同 Agent 同 UUID 冲突。

4. Hook 事件、Agent 卡片和额度扫描均使用同一 key。

### 测试

- Kimi `uuid` 与 `session_uuid` 能映射到同一 key。
- Claude 和 Kimi 使用相同 UUID 时互不覆盖。
- Agent 卡片能拿到对应 token。

## P1-12 剪贴板切换器用稳定 ID 保存选择

### 涉及文件

- `Sources/ProNotch/Clipboard/ClipboardSwitcher.swift`
- `Sources/ProNotch/Clipboard/ClipboardStore.swift`

### 当前风险

面板使用数组下标保存选中集合。面板打开期间新剪贴板插入索引 0 后，下标整体移动，可能粘贴另一条内容。

### 必须实施

1. 选择集合使用稳定 ID：

```swift
enum SwitcherItemID: Hashable {
    case history(UUID)
    case snippet(UUID)
}
```

2. 键盘导航可以临时计算当前 index，但持久选择、锚点、双击目标和批量复制都以 ID 为准。

3. 项目新增、删除、重排时清理失效 ID，并保持仍存在的选择。

4. 模式切换时选择状态明确重置或分别保存，行为写入测试。

### 测试

- 选中第二条后插入新第一条，最终仍复制原第二条。
- 删除选中项后选择安全移动。
- 多选期间插入和删除不会复制错误条目。
- 话术重排后选中项身份不变。

## P1-13 天气响应数组长度不一致时安全失败

### 涉及文件

- `Sources/ProNotch/Widgets/WeatherStore.swift`

### 必须实施

1. 把 Open Meteo 响应到 `WeatherNow` 的映射抽为可测试纯函数。

2. 小时数据使用所有必需数组的最小长度。每日数据同理。

3. 当前索引必须落在有效公共范围内。

4. 核心数组为空或明显不一致时返回结构化错误，不发生下标越界。

5. 可选数组继续安全下标读取。

### 测试

- time 比 temperature 长。
- weather_code 为空。
- daily max/min 长度不同。
- sunrise/sunset 缺失。
- 完整响应输出保持现有结果。

## P1-14 QuickActions 等待进程退出并校验状态码

### 涉及文件

- `Sources/ProNotch/QuickActions/QuickActionsStore.swift`

### 必须实施

1. 抽象进程执行器，后台等待退出，收集 `terminationStatus` 和 stderr。

2. `osascript`、`defaults`、`killall Finder` 只有状态码 0 才更新 UI。

3. 失败时保持旧状态并显示或发布错误。

4. 成功后重新读取系统真实状态，不只依赖预设值。

### 测试

- 进程启动成功但退出码非 0，状态不改变。
- 成功退出后状态更新。
- stderr 被转为用户可理解错误且不泄露敏感信息。

## P1-15 Claude Desktop Cookie 读取使用一致 SQLite 快照并校验 host hash

### 涉及文件

- `Sources/ProNotch/Usage/CCDCookieReader.swift`

### 必须实施

1. 使用 SQLite backup API 创建一致快照，或完整复制主 DB、WAL、SHM 并证明一致性。优先 SQLite backup API。

2. 临时数据库放入独立临时目录，结束后清理。

3. `decrypt` 接收 host。只有解密明文前 32 字节确实等于 `SHA256(host)` 时才移除 host hash。

4. 不符合 host hash 时保留完整明文，兼容旧数据库格式。

5. SQLite 错误进入诊断日志，不打印 cookie。

### 测试

- 带正确 host hash 的明文被正确剥离。
- 长度大于 32 但 hash 不匹配时不误截断。
- WAL 中的新 cookie 能从快照读取。
- 临时文件被清理。

## P1-16 更新下载 URL 固定到官方仓库

### 涉及文件

- `Sources/ProNotch/UpdateChecker.swift`
- `Sources/ProNotch/Update/UpdatePresenter.swift`

### 必须实施

1. CDN `version.json` 只信任版本号。下载 URL 由代码根据固定仓库生成。

2. GitHub API 返回的 `html_url` 也通过验证：

- scheme 为 HTTPS。
- host 为 `github.com`。
- path 属于 `/DaliangPro/ProNotch/releases/`。

3. 验证失败时使用固定 `releases/latest` 地址。

### 测试

- CDN 返回恶意 URL 时仍打开官方 Release。
- 合法 tag URL 保留。
- HTTP、其他域名、其他仓库路径被拒绝。

## P1-17 内存进程排行移出 MainActor

### 涉及文件

- `Sources/ProNotch/Widgets/MemoryStore.swift`

### 必须实施

1. 进程枚举、rusage 读取、路径聚合和排序放后台执行。

2. 后台只返回纯数据，不在后台创建或操作 `NSImage`。

3. 主线程只对最终 Top N 解析本地化名称、读取图标并发布。

4. 防止三秒计时器触发重叠扫描。已有扫描进行中时合并或跳过。

5. Store 销毁时取消任务。

### 测试

- 聚合纯函数测试继续通过。
- 重叠 refresh 不产生两个并发全量扫描。
- 旧扫描结果不能覆盖更新扫描。

## P1-18 截图写盘失败时保留结果并允许重试

### 涉及文件

- `Sources/ProNotch/Screenshot/ScreenshotOverlayView.swift`
- `Sources/ProNotch/Screenshot/LongShot.swift`

### 必须实施

1. 普通截图和长截图写盘函数返回 `Result<URL, Error>`。

2. PNG 编码失败或写入失败时：

- 不关闭 overlay。
- 不清理长截图结果。
- 显示明确错误。
- 保留复制、重试保存和丢弃操作。

3. 写入成功后才关闭并清理。

4. 文件名冲突使用安全唯一策略。

5. 为文件写入增加可注入 writer，测试磁盘错误。

### 测试

- 模拟写入失败，结果仍存在。
- 第二次重试成功后才关闭。
- 编码失败不丢失原 CGImage。

# 第三阶段：安全与维护加固

## P2-19 给 `pronotch://done` Hook 回调增加认证令牌

### 涉及文件

- `Sources/ProNotch/Glow/GlowHookInstaller.swift`
- `Sources/ProNotch/AppDelegate.swift`
- URL scheme 处理逻辑

### 必须实施

1. 首次安装 Hook 时生成随机高熵 token，存放在 Application Support 中，权限 0600。

2. 四家 Hook 脚本的 URL 都附带 token。

3. 应用收到 `pronotch://done` 时使用恒定时间比较校验 token。失败直接忽略，不更新 host/session 映射，不亮光晕。

4. 递增 Hook script format，让已启用 Hook 自动升级。

5. 正式版拒绝无 token 回调。DEBUG 可保留单独明确的调试路径。

### 测试

- 正确 token 接受。
- 缺 token、错误 token 拒绝。
- 老脚本升级后带 token。
- 日志不输出 token。

## P2-20 移除私有 NSCursor selector

### 涉及文件

- `Sources/ProNotch/Screenshot/ScreenshotOverlayView.swift`

### 必须实施

将 `_windowResizeNorthWestSouthEastCursor` 等私有 selector 替换为：

- 应用内自绘对角缩放光标，或
- 公开 API 的稳定降级方案。

不得再通过 `perform` 调用私有 AppKit selector。

### 测试与验收

macOS 14 上四角拖拽仍有清晰光标反馈，代码中搜索不到私有 selector 名称。

## P2-21 隐私日志统一使用 Logger

### 涉及文件

- ChatStore
- WebSearch
- ScreenshotTranslator
- Agent 相关 Store
- 其他打印用户查询、项目路径或响应正文的位置

### 必须实施

1. 使用 `Logger(subsystem:category:)`。

2. 用户问题、搜索词、项目路径、会话标题、HTTP body、cookie、API Key 使用 private 隐私级别或完全不记录。

3. 保留必要的状态码、计数和阶段信息。

4. DEBUG 诊断也不要打印 Key 和 cookie。

## P2-22 收紧签名私钥 ACL

### 涉及文件

- 创建签名证书的脚本，预计位于 `Scripts`

### 必须实施

移除宽泛的 `security import ... -A`。只授权实际需要的 codesign 工具，必要时使用 partition list。脚本输出说明同步更新。

# 4. 跨模块设计要求

## 4.1 统一依赖注入边界

为下列系统依赖提供小型协议，不要把整个 Store 改成复杂框架：

- Keychain
- HTTP transport
- DNS resolver
- 文件持久化
- Process runner
- Screenshot window capture
- 时间和 UUID，仅在测试需要时注入

生产默认实现可以通过 init 默认参数提供，现有调用方尽量少改。

## 4.2 统一代际校验模式

异步对象建议使用同一模式：

```swift
let generation = currentGeneration
let identity = currentIdentity
let result = await work()
guard generation == currentGeneration,
      identity == currentIdentity else { return }
publish(result)
```

适用范围：

- Provider Key 回填
- 模型列表
- API 连通检测
- UsageStore 刷新
- AgentSessionsStore 刷新
- 窗口 shape 捕获
- 长截图结果

## 4.3 错误展示

用户可直接触发的动作失败时应有可见反馈：

- 保存截图
- 修改 Agent Hook
- API 端点被安全策略拒绝
- 系统外观或净屏命令失败

后台维护任务可使用日志，但不能静默破坏数据。

## 4.4 数据兼容

不得破坏：

- 现有 UserDefaults key。
- 现有 Keychain account。
- 现有聊天 JSON。
- 现有剪贴板索引和图片。
- 现有话术 JSON。
- 现有 Agent Hook 配置。

需要升级格式时，实现幂等迁移和旧格式测试。

# 5. 自动化测试总清单

最终至少应新增或扩展下列测试文件：

- `KeychainMigrationTests.swift`
- `ChatProviderIsolationTests.swift`
- `EndpointPolicyTests.swift`
- `SafeWebFetcherTests.swift`
- `ChatSearchPromptSecurityTests.swift`
- `ScreenshotTranslationProviderTests.swift`
- `GlowHookInstallerConfigTests.swift`
- `WindowShapeCaptureRaceTests.swift`
- `LongShotConcurrencyAndLimitsTests.swift`
- `StoreRefreshGenerationTests.swift`
- `AtomicPersistenceTests.swift`
- `AgentSessionKeyTests.swift`
- `ClipboardSwitcherSelectionTests.swift`
- `WeatherResponseMappingTests.swift`
- `ProcessRunnerTests.swift`
- `CCDCookieReaderTests.swift`
- `UpdateURLValidationTests.swift`
- `ScreenshotSaveFailureTests.swift`
- `HookCallbackAuthenticationTests.swift`

测试命名可调整，但覆盖内容不可省略。

# 6. 人工回归清单

自动化通过后，在 macOS 真机按以下顺序回归：

1. 首次启动，旧 NotchHub 数据迁移。
2. 钥匙串授权点拒绝一次，确认旧 Key 未丢；再次启动允许后迁移成功。
3. 创建三套 AI Provider，快速切换并分别测试模型列表、连通性、聊天。
4. A Provider 发消息后立即切 B，A 回复继续进入原会话且使用 A 模型。
5. 当前 Provider 切换后执行截图翻译。
6. HTTPS 远程 API 可用；localhost HTTP 可用；公网 HTTP 被拒绝。
7. DuckDuckGo 搜索正文抓取正常；恶意或内网 URL 被拒绝并降级摘要。
8. Claude、Codex、Kimi、Grok Hook 安装、重复安装、卸载，原配置保留。
9. 快速在两个窗口间吸附并立即复制，内容与最终选中窗口一致。
10. 长截图向上、向下、暂停、恢复、停止、取消、双击预览。
11. 长截图达到安全上限后自动收尾。
12. 模拟桌面不可写，普通截图和长截图都保留结果并显示错误。
13. Agent 开关在刷新过程中快速切换，已关 Agent 不会重新出现。
14. 剪贴板面板打开时复制一条新内容，原选中项仍正确。
15. 天气接口失败和异常数据不会崩溃。
16. 外观切换权限拒绝时 UI 不显示虚假成功。
17. 更新检查只打开官方仓库 Release。
18. Release 构建中调试通道和无 token Hook 回调不可用。

# 7. 最终交付格式

完成后请输出一份结构化总结，包含：

1. 基线提交与最终 HEAD。
2. 每个提交的 SHA 和一句说明。
3. 修改过的文件清单。
4. 新增测试及其覆盖问题。
5. 实际执行过的命令和结果。
6. 未能执行的真机或签名验证及原因。
7. 仍存在的残余风险。
8. 任何行为变化，尤其是 HTTP 端点规则和 Hook 自动升级。

不要只说“已修复”。给出可以审计的证据，包括测试名、命令结果和关键设计。

# 8. 开始执行时的第一条 Claude Code 指令

在仓库根目录先执行以下命令，然后从 P0-01 开始：

```bash
git status --short
git rev-parse HEAD
swift build
swift test
```

确认基线后创建修复分支，按本任务书顺序实施。遇到现有代码路径与任务书略有差异时，以符号名和真实调用链为准，保持目标与验收条件不变。
