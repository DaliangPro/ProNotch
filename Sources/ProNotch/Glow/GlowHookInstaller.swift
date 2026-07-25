import Foundation

/// 把「完成提醒」接入 / 移出各家 Agent。机制各不相同：
/// - Claude Code：原生 Stop 钩子（`~/.claude/settings.json`），追加一条转发脚本。
/// - Codex：完成事件只走 `config.toml` 的 `notify`（单程序）。我们装一个转发脚本——
///   先 `open pronotch://` 点亮光晕，再把通知原样透传给原有的 `notify`（保留 computer-use
///   等下游不被打断）。原 `notify` 以 base64 存进脚本头部，卸载时据此还原。
/// - Kimi Code：`~/.kimi-code/config.toml` 的 `[[hooks]]` 数组表（官方 Stop 事件，
///   stdin JSON 带 session_id，与 Claude 同构）——追加带边界标记的一段，卸载时整段删除。
/// - Grok CLI：`~/.grok/hooks/` 全局钩子目录，每个应用一个独立 JSON 文件（Claude 同构
///   schema，机内 vibe-island.json 为实证）——我们写 `pronotch.json`，卸载时整文件删除。
///
/// 一致性原则（四家统一）：
/// 1. 改配置前先备份（两代轮换）。
/// 2. 配置一律经 `AtomicConfigWriter` 写：同目录临时文件 → 结构校验 → 原子替换，
///    失败时原文件字节不变。
/// 3. 安装时脚本先落到临时文件，配置替换成功后才把脚本原子挪到位；
///    卸载时先改配置，成功后才删脚本。任一步失败都不会留下「配置指向不存在的脚本」
///    或「脚本在但配置没接上」的半截状态。
/// 4. 无法唯一确定要删的范围时返回失败，保持原文件——宁可让用户手动清理，
///    也不能把别人的配置删掉。
enum GlowHookInstaller {

    // MARK: - 对外接口（按来源分流）

    static func isInstalled(_ source: AgentKind, paths: GlowHookPaths = .production) -> Bool {
        switch source {
        case .claude: return isClaudeInstalled(paths)
        case .codex:  return isCodexInstalled(paths)
        case .kimi:   return isKimiInstalled(paths)
        case .grok:   return isGrokInstalled(paths)
        }
    }

    @discardableResult
    static func setInstalled(_ source: AgentKind, _ on: Bool,
                             paths: GlowHookPaths = .production) -> Bool {
        switch source {
        case .claude: return setClaudeInstalled(on, paths)
        case .codex:  return setCodexInstalled(on, paths)
        case .kimi:   return setKimiInstalled(on, paths)
        case .grok:   return setGrokInstalled(on, paths)
        }
    }

    /// 升级迁移：仅把「已接入」的来源刷新到当前脚本格式，不改变接入与否
    static func migrateIfInstalled(_ source: AgentKind, paths: GlowHookPaths = .production) {
        guard isInstalled(source, paths: paths) else { return }
        setInstalled(source, true, paths: paths)
    }

    /// 清除早期版本（43640d8）写进 ~/.codex/hooks.json 的 pronotch Stop 钩子孤儿。
    /// 现在 Codex 完成提醒走 config.toml 的 notify，这条孤儿会让每次完成多发一个「无 host」
    /// 信号——表现为：终端在前台时光晕仍亮、且只能靠激活 Codex 桌面 App 才能熄灭。
    @discardableResult
    static func cleanCodexHooksOrphan(paths: GlowHookPaths = .production) -> Bool {
        let p = paths.codexHooks
        guard let data = FileManager.default.contents(atPath: p),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any],
              var stop = hooks["Stop"] as? [[String: Any]] else { return false }
        let before = stop.count
        stop.removeAll { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("pronotch://done") == true
            } == true
        }
        guard stop.count != before else { return false }   // 无孤儿则不动文件
        AtomicConfigWriter.backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return writeJSON(root, to: p)
    }

    /// hook 脚本格式版本：升级时 +1，启动迁移据此把旧脚本刷新到新格式
    /// v4：URL 追加 session（Claude 读 stdin 的 session_id / Codex 读 payload 的 thread-id），供 Agent 页瞬时点亮
    /// v5：URL 追加 token，应用侧恒定时间校验；无令牌的回调一律丢弃
    /// v6：投递前先确认 ProNotch 在运行，不再把退出的 App 拉起来
    /// v7：后台子任务还在跑就不提醒（background_tasks 非空即闭嘴）
    /// v8：四家各加挂一条 UserPromptSubmit 开工信号，供刘海收起态槽位显示工作状态
    /// v9：Claude / Kimi 加挂 Notification 事件，中途弹框等你拍板时刘海弹卡提醒
    /// v10：Claude 加挂 PermissionRequest 事件，授权直接在刘海卡上拍板（终端不再弹框）
    private static let scriptFormat = 10

    /// 投递回调前先确认 ProNotch 还在运行。
    ///
    /// 病灶：`open` 遇到没在运行的 App 会**先把它启动起来**再投递 URL。
    /// 于是用户前脚手动退出 ProNotch，后脚 Agent 干完一轮活，hook 就把它拉了回来——
    /// 用户看到的是「关不掉，它自己又开了」。`-g` 不抢焦点，连个窗口都不弹，
    /// 只有菜单栏图标默默出现，更难归因。
    ///
    /// 用 `if` 而不是 `pgrep … || exit 0`：
    /// - Codex 脚本在这之后还要 exec 转发给原有的 notify，中途 exit 会把别人的链也掐断；
    /// - Stop hook 返回非零退出码会被 Claude Code 当成 hook 失败报错。
    private static let deliverGuard =
        #"if /usr/bin/pgrep -x ProNotch >/dev/null 2>&1; then open -g "$url"; fi"#

    /// 沿进程链向上找到「Agent 实际所在的 GUI App」bundle id。只认 /Applications 下的 app
    /// （借此排除 claude-code 的 CLI 包装 app）；终端 / IDE / 桌面 App 通用，找不到回空。
    private static let hostDetectSnippet = """
    detect_host() {
      local pid=$PPID ppid path app bid
      for _ in $(seq 1 15); do
        [ "$pid" -le 1 ] && break
        read -r ppid path < <(ps -o ppid=,comm= -p "$pid" 2>/dev/null)
        [ -z "$ppid" ] && break
        case "$path" in
          */Applications/*.app/Contents/*)
            app="${path%%.app/Contents/*}.app"
            bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)
            [ -n "$bid" ] && { printf '%s' "$bid"; return; } ;;
        esac
        pid=$ppid
      done
    }
    """

    /// 脚本是否已是当前格式（含 host 探测、且带当前令牌）：据脚本头的 PRONOTCH_FMT 标记判断。
    /// 令牌也要验——令牌一旦轮换，旧脚本带的还是作废的那枚，必须重写才认得回来
    private static func scriptIsCurrent(_ path: String, token: String) -> Bool {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return s.contains("PRONOTCH_FMT=\(scriptFormat)") && s.contains("token=\(token)")
    }

    /// 把载荷压掉全部空白再比对结构键：JSON 序列化带不带空格因实现而异，
    /// 压平之后 `"background_tasks": []` 与 `"background_tasks":[]` 长得一模一样，
    /// 下面的 case 就不必为每种排版各写一条 pattern
    private static let compactSnippet =
        #"compact=$(printf '%s' "$payload" | tr -d '[:space:]')"#

    /// 「主 Agent 回合结束」≠「任务完成」，别把前者当后者报。
    ///
    /// 病灶：派出后台子 Agent 的那一刻主回合就结束了，触发一次货真价实的 Stop；
    /// 此后每个子 Agent 完成都会唤醒主循环、再产生一个短回合、再触发一次 Stop。
    /// 用户看到的就是「一个 sub Agent 干完就提醒，可整个任务还早着呢」。
    ///
    /// 判据不能用事件名——Stop 与 SubagentStop 在 Claude Code 里本就互斥
    /// （分发处只有一句 `let l = o ? "SubagentStop" : "Stop"`，且只查这一个事件名的
    /// 注册表），只注册 Stop 的我们压根不会被子 Agent 调用。真正的判据是载荷里的
    /// `background_tasks`：它只收 status ∈ {running, pending} 且未被前台化的任务，
    /// 非空就说明后台还有活在跑，这次 Stop 不该响。
    ///
    /// 字段缺失一律放行：老版本 Claude Code 不带它，Kimi / Grok 更没有。
    /// 认不出来就维持原有行为——不能因为读不到就把提醒全吞了。
    private static let backgroundTasksGuard = """
    case "$compact" in
      *'"background_tasks":[]'*) ;;
      *'"background_tasks":['*) exit 0 ;;
    esac
    """

    /// 事件名对不上就丢弃：本脚本只处理主 Agent 的 Stop。
    ///
    /// 目前 ProNotch 只往 `Stop` 上注册，这条纯属兜底——但用户会自己往 hooks 里加东西
    /// （这台机器上 vibe-island 就挂了 13 个事件），万一哪天本脚本被挂到 SubagentStop
    /// 之类的事件上，有这条就不会误报。
    ///
    /// 只给 Claude 用：`"hook_event_name":"Stop"` 这个取值是在 Claude Code 二进制里
    /// 实证过的；Kimi / Grok 的事件名拼写没核实，照搬同一套过滤有把它们正常回调
    /// 全吞掉的风险。
    private static let claudeEventGuard = """
    case "$compact" in
      *'"hook_event_name":"Stop"'*) ;;
      *'"hook_event_name":'*) exit 0 ;;
    esac
    """

    /// 「开始工作」信号脚本：四家共用，来源经 `$1` 传入。
    ///
    /// 挂在各家的 `UserPromptSubmit` 上——用户提交提问即开工，回合结束的 done 回调即收工，
    /// 一个回合恰好两个事件，零轮询。这是刘海收起态唯一拿得到「正在工作」的路子：
    /// AgentSessionsStore 收起时根本不扫描，而光晕链路只有「刚完成」没有「开始」。
    private static func busyNotifyScript(token: String) -> String {
        """
        #!/bin/bash
        # ProNotch · Agent 开始工作信号（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        src="$1"
        [ -n "$src" ] || exit 0
        # stdin 是终端就别 cat：各家在 UserPromptSubmit 上是否喂管道没有逐一实证过，
        # 真赶上没喂的，cat 会一直等到 hook 超时——每次提问卡上几秒，比不显示状态糟得多
        if [ -t 0 ]; then payload=""; else payload=$(cat); fi
        host=$(detect_host)
        # session_id 是 Claude / Kimi / Grok 的叫法，thread-id 是 Codex 的；抓不到就不带，
        # 应用侧会退化成「把这一家整个标记为工作中」
        sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        [ -n "$sid" ] || sid=$(printf '%s' "$payload" | sed -n 's/.*"thread-id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        url="pronotch://busy?source=$src&token=\(token)"
        [ -n "$host" ] && url="$url&host=$host"
        [ -n "$sid" ] && url="$url&session=$sid"
        \(deliverGuard)
        """
    }

    /// 注册进各家配置的 busy 命令行。路径含空格（Application Support），须引号包裹
    private static func busyCommand(_ paths: GlowHookPaths, source: String) -> String {
        "\"\(paths.busyScript)\" \(source)"
    }

    /// 「等你拍板」信号脚本：Claude / Kimi 共用，来源经 `$1` 传入。
    ///
    /// 挂在各家的 `Notification` 事件上——Agent 跑到一半弹了授权框 / 选项框在等你选，
    /// 这时既没有 Stop（回合没结束）也没有新的 UserPromptSubmit，是此前唯一没有任何
    /// 提示的空档（大梁老师指出）。Claude Code 自带约 6 秒延迟才发这个事件，
    /// 所以「你人就在跟前」时本来就不会响。
    ///
    /// 脚本只负责搬运，不做「哪种通知才值得弹」的判断——那份名单在
    /// `AgentWaitPolicy` 里，改它不必让用户重装 hook。
    ///
    /// 项目名走 base64url 而不是直接拼进 query：目录名可以带空格和中文，
    /// 裸拼会让 URL 在 `open` 或 URLComponents 那一关散架
    private static func waitNotifyScript(token: String) -> String {
        """
        #!/bin/bash
        # ProNotch · Agent 等你拍板信号（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        src="$1"
        [ -n "$src" ] || exit 0
        if [ -t 0 ]; then payload=""; else payload=$(cat); fi
        host=$(detect_host)
        sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        ntype=$(printf '%s' "$payload" | sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        cwd=$(printf '%s' "$payload" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        proj=$(printf '%s' "${cwd##*/}" | base64 | tr -d '\\n' | tr '+/' '-_' | tr -d '=')
        url="pronotch://waiting?source=$src&token=\(token)"
        [ -n "$host" ] && url="$url&host=$host"
        [ -n "$sid" ] && url="$url&session=$sid"
        [ -n "$ntype" ] && url="$url&type=$ntype"
        [ -n "$proj" ] && url="$url&project=$proj"
        \(deliverGuard)
        """
    }

    /// 注册进各家配置的 wait 命令行（同 busyCommand，路径须引号包裹）
    private static func waitCommand(_ paths: GlowHookPaths, source: String) -> String {
        "\"\(paths.waitScript)\" \(source)"
    }

    /// 把共用的 wait 脚本落位（已是当前格式就不动）。理由同 ensureBusyScript：
    /// 没人引用的脚本只是无害孤儿，配置指向不存在的脚本才会每次事件都报 hook 失败
    private static func ensureWaitScript(token: String, _ paths: GlowHookPaths) -> Bool {
        if scriptIsCurrent(paths.waitScript, token: token) { return true }
        guard let staged = AtomicConfigWriter.stageScript(waitNotifyScript(token: token),
                                                         finalPath: paths.waitScript) else { return false }
        return AtomicConfigWriter.commitScript(from: staged, to: paths.waitScript)
    }

    /// 支持该能力的家全退干净了才收走共用脚本，不留孤儿也不误删还在被别家引用的
    private static func cleanupWaitScriptIfUnused(_ paths: GlowHookPaths) {
        let stillUsed = AgentKind.allCases.contains {
            $0.supportsWaitNotice && isInstalled($0, paths: paths)
        }
        guard !stillUsed else { return }
        try? FileManager.default.removeItem(atPath: paths.waitScript)
    }

    /// 拍板脚本的等待上限（秒）。写进配置的 `timeout`，Claude Code 到点会掐掉本脚本，
    /// 那时它拿不到决策，就落回终端正常弹框——数据不会丢，只是卡白弹了一场。
    ///
    /// 大梁老师定的是「一直等到答复」，所以给到 6 小时：卡不会自己消失，
    /// 人回来了照样能在卡上点。schema 里 timeout 只要求 positive、没有上限（已核对 zod 定义）
    static let permissionWaitSeconds = 21600

    /// 「在刘海上直接拍板」脚本：只有 Claude Code 一家。
    ///
    /// 挂在 `PermissionRequest` 上——这个事件在**终端弹框之前**触发，从二进制里抠出的
    /// 实现（`NpT`）只认 allow / deny 两种回答，其余一律 `return`，也就是落回终端正常弹框。
    /// 于是「不答」天然就是安全的兜底：ProNotch 没开、脚本出错、用户选「打开终端」，
    /// 结果都一样——终端照原样问，什么都不会丢。
    ///
    /// 脚本刻意只当一根管子：写请求文件 → 投一条带 id 的 URL → 等答复文件 → 原样吐出。
    /// 因为要回传的 `updatedPermissions`（「不再询问」那条规则）是入参 `permission_suggestions`
    /// 的原样透传，是嵌套 JSON —— bash 里拿 sed 抠这种东西迟早出事，也没必要：
    /// 整份答复由 Swift 拼好，脚本 `cat` 一下就完了
    private static func permissionAskScript(token: String, dir: String) -> String {
        """
        #!/bin/bash
        # ProNotch · Agent 权限拍板（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        src="$1"
        [ -n "$src" ] || exit 0
        # 没喂 stdin 就没有 tool_input 可看，卡上等于什么都显示不了 —— 直接让终端问
        [ -t 0 ] && exit 0
        payload=$(cat)
        [ -n "$payload" ] || exit 0
        # 没开着就别拦：这里必须先于写请求文件，否则会攒下一地没人取的孤儿
        /usr/bin/pgrep -x ProNotch >/dev/null 2>&1 || exit 0
        dir="\(dir)"
        /bin/mkdir -p "$dir" 2>/dev/null || exit 0
        /bin/chmod 700 "$dir" 2>/dev/null
        # id 必须不可猜：别的本机进程猜中了就能替你按下「允许」
        id=$(/usr/bin/head -c 16 /dev/urandom | /usr/bin/xxd -p | /usr/bin/tr -d '\\n')
        [ -n "$id" ] || exit 0
        req="$dir/$id.request.json"
        res="$dir/$id.response.json"
        umask 077
        printf '%s' "$payload" > "$req" || exit 0
        host=$(detect_host)
        url="pronotch://permission?source=$src&token=\(token)&req=$id"
        [ -n "$host" ] && url="$url&host=$host"
        # 投递前再确认一次：上面那次 pgrep 到这里之间，用户完全可能刚把 ProNotch 关掉，
        # 而 open 遇到没在跑的 App 会**把它启动起来**——那正是「关不掉，它自己又开了」那个病
        \(deliverGuard)
        # 第一段：等它把请求取走。ProNotch 取走的标志就是请求文件消失（它读完即删）。
        # 一直没人取＝这条 URL 没送达（LaunchServices 抽风、刘海刚好被强杀）——
        # 这时不能干等：卡根本没弹出来，「一直等到答复」等的是谁？约 10 秒后落回终端问
        n=0
        while [ -f "$req" ]; do
          [ -f "$res" ] && break
          /usr/bin/pgrep -x ProNotch >/dev/null 2>&1 || { /bin/rm -f "$req"; exit 0; }
          n=$((n+1))
          [ "$n" -gt 50 ] && { /bin/rm -f "$req"; exit 0; }
          /bin/sleep 0.2
        done
        # 第二段：卡已经挂在刘海上了，等到答复为止（大梁老师定：不自己超时）。
        # 只有一种情况提前收手：ProNotch 退出了，没人会来答了
        while [ ! -f "$res" ]; do
          /usr/bin/pgrep -x ProNotch >/dev/null 2>&1 || exit 0
          /bin/sleep 0.2
        done
        # 「打开终端」写的是空文件：空 stdout 在 Claude Code 那边就是「没决策」，照旧弹框
        /bin/cat "$res"
        /bin/rm -f "$req" "$res"
        exit 0
        """
    }

    /// 注册进 Claude settings.json 的拍板命令行（路径含空格，须引号包裹）
    private static func permissionCommand(_ paths: GlowHookPaths) -> String {
        "\"\(paths.permissionScript)\" claude"
    }

    /// 把拍板脚本落位（已是当前格式就不动）。理由同 ensureBusyScript
    private static func ensurePermissionScript(token: String, _ paths: GlowHookPaths) -> Bool {
        if scriptIsCurrent(paths.permissionScript, token: token) { return true }
        guard let staged = AtomicConfigWriter.stageScript(
                permissionAskScript(token: token, dir: paths.permissionDir),
                finalPath: paths.permissionScript) else { return false }
        return AtomicConfigWriter.commitScript(from: staged, to: paths.permissionScript)
    }

    /// 只有 Claude 挂它，那家退了就收走。交换目录一并清掉：里面躺的是
    /// 还没答复的请求，钩子都卸了也不会有人来取了
    private static func cleanupPermissionScriptIfUnused(_ paths: GlowHookPaths) {
        guard !AgentKind.allCases.contains(where: {
            $0.supportsPermissionCard && isInstalled($0, paths: paths)
        }) else { return }
        try? FileManager.default.removeItem(atPath: paths.permissionScript)
        try? FileManager.default.removeItem(atPath: paths.permissionDir)
    }

    /// 把共用的 busy 脚本落位（已是当前格式就不动）。四家都会调它，内容相同，重复调用无副作用。
    ///
    /// 刻意在写配置**之前**落位：没人引用的脚本只是个无害孤儿，
    /// 而配置指向一个不存在的脚本，会让每次 UserPromptSubmit 都报 hook 失败
    private static func ensureBusyScript(token: String, _ paths: GlowHookPaths) -> Bool {
        if scriptIsCurrent(paths.busyScript, token: token) { return true }
        guard let staged = AtomicConfigWriter.stageScript(busyNotifyScript(token: token),
                                                          finalPath: paths.busyScript) else { return false }
        return AtomicConfigWriter.commitScript(from: staged, to: paths.busyScript)
    }

    /// 四家都退干净了才收走共用脚本，不留孤儿也不误删还在被别家引用的
    private static func cleanupBusyScriptIfUnused(_ paths: GlowHookPaths) {
        guard !AgentKind.allCases.contains(where: { isInstalled($0, paths: paths) }) else { return }
        try? FileManager.default.removeItem(atPath: paths.busyScript)
    }

    /// stdin JSON 型转发脚本（Claude / Kimi / Grok 三家同构）
    private static func stdinNotifyScript(source: String, token: String) -> String {
        var guards = [compactSnippet, backgroundTasksGuard]
        if source == "claude" { guards.append(claudeEventGuard) }
        return """
        #!/bin/bash
        # ProNotch · \(source) 完成提醒（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        \(hostDetectSnippet)
        payload=$(cat)
        \(guards.joined(separator: "\n"))
        host=$(detect_host)
        sid=$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
        url="pronotch://done?source=\(source)&token=\(token)"
        [ -n "$host" ] && url="$url&host=$host"
        [ -n "$sid" ] && url="$url&session=$sid"
        \(deliverGuard)
        """
    }

    /// JSON 配置的原子写入：序列化 + 回读校验，坏内容不落盘
    private static func writeJSON(_ root: [String: Any], to path: String) -> Bool {
        guard let out = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              (try? JSONSerialization.jsonObject(with: out)) != nil else { return false }
        return AtomicConfigWriter.writeData(out, to: path).isSuccess
    }

    // MARK: - Claude Code（~/.claude/settings.json 的 Stop 钩子）

    private static func claudeCommand(_ paths: GlowHookPaths) -> String { "\"\(paths.claudeScript)\"" }

    /// 旧版（内联 open pronotch://）或新版（指向脚本）都算「我们的」——卸载/迁移时一并处理
    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            let c = ($0["command"] as? String) ?? ""
            return c.contains("pronotch://done") || c.contains("claude-notify.sh")
        } == true
    }
    /// 仅新版（command 指向我们的脚本）
    private static func entryIsCurrentClaude(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            ($0["command"] as? String)?.contains("claude-notify.sh") == true
        } == true
    }
    /// 开工信号条目（挂在 UserPromptSubmit 上）。与 `entryIsOurs` 认的是两拨不同的
    /// 特征串（busy / agent-busy.sh vs done / claude-notify.sh），互不误伤
    private static func entryIsOurBusy(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            let c = ($0["command"] as? String) ?? ""
            return c.contains("pronotch://busy") || c.contains("agent-busy.sh")
        } == true
    }
    /// 「等你拍板」条目（挂在 Notification 上）。特征串同样与前两拨互不重叠
    private static func entryIsOurWait(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            let c = ($0["command"] as? String) ?? ""
            return c.contains("pronotch://waiting") || c.contains("agent-wait.sh")
        } == true
    }
    /// 拍板条目（挂在 PermissionRequest 上）。特征串与前三拨仍不重叠
    private static func entryIsOurPermission(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains {
            let c = ($0["command"] as? String) ?? ""
            return c.contains("pronotch://permission") || c.contains("agent-permission.sh")
        } == true
    }

    private static func isClaudeInstalled(_ paths: GlowHookPaths) -> Bool {
        guard let data = FileManager.default.contents(atPath: paths.claudeSettings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [[String: Any]] else { return false }
        return stop.contains(where: entryIsOurs)
    }

    @discardableResult
    private static func setClaudeInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let p = paths.claudeSettings
        let fm = FileManager.default
        guard fm.fileExists(atPath: (p as NSString).deletingLastPathComponent) else { return false }

        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: p) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var stop = hooks["Stop"] as? [[String: Any]] ?? []
        var prompt = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
        var notif = hooks["Notification"] as? [[String: Any]] ?? []
        var perm = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        let oursEntries = stop.filter(entryIsOurs)
        let ourBusyEntries = prompt.filter(entryIsOurBusy)
        let ourWaitEntries = notif.filter(entryIsOurWait)
        let ourPermEntries = perm.filter(entryIsOurPermission)

        var staged: String?
        if on {
            // 拿不到令牌就不装：装了也是一条谁都能伪造的回调，不如不装
            guard let token = GlowHookToken.ensure(paths) else { return false }
            // 已是当前格式（四个脚本都最新 + 四个事件各仅一条指向脚本的条目）→ 幂等跳过
            if scriptIsCurrent(paths.claudeScript, token: token),
               scriptIsCurrent(paths.busyScript, token: token),
               scriptIsCurrent(paths.waitScript, token: token),
               scriptIsCurrent(paths.permissionScript, token: token),
               oursEntries.count == 1, entryIsCurrentClaude(oursEntries[0]),
               ourBusyEntries.count == 1, ourWaitEntries.count == 1,
               ourPermEntries.count == 1 { return true }
            staged = AtomicConfigWriter.stageScript(stdinNotifyScript(source: "claude", token: token),
                                                    finalPath: paths.claudeScript)
            guard staged != nil else { return false }
            // 三个共用脚本先落位，配置才敢指过去
            guard ensureBusyScript(token: token, paths), ensureWaitScript(token: token, paths),
                  ensurePermissionScript(token: token, paths) else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            stop.removeAll(where: entryIsOurs)   // 清掉旧内联 / 重复条目，再装新版
            stop.append(["hooks": [["type": "command", "command": claudeCommand(paths)]]])
            prompt.removeAll(where: entryIsOurBusy)
            prompt.append(["hooks": [["type": "command",
                                      "command": busyCommand(paths, source: "claude")]]])
            notif.removeAll(where: entryIsOurWait)
            notif.append(["hooks": [["type": "command",
                                     "command": waitCommand(paths, source: "claude")]]])
            // 拍板这条要带 timeout：默认超时远短于人走回电脑前的时间，
            // 到点被掐就白弹一张卡（终端会照常问，不丢事，但提醒等于没起作用）
            perm.removeAll(where: entryIsOurPermission)
            perm.append(["hooks": [["type": "command",
                                    "command": permissionCommand(paths),
                                    "timeout": permissionWaitSeconds]]])
        } else {
            if oursEntries.isEmpty, ourBusyEntries.isEmpty, ourWaitEntries.isEmpty,
               ourPermEntries.isEmpty { return true }
            stop.removeAll(where: entryIsOurs)
            prompt.removeAll(where: entryIsOurBusy)
            notif.removeAll(where: entryIsOurWait)
            perm.removeAll(where: entryIsOurPermission)
        }

        AtomicConfigWriter.backup(p)
        if stop.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = stop }
        if prompt.isEmpty {
            hooks.removeValue(forKey: "UserPromptSubmit")
        } else {
            hooks["UserPromptSubmit"] = prompt
        }
        if notif.isEmpty {
            hooks.removeValue(forKey: "Notification")
        } else {
            hooks["Notification"] = notif
        }
        if perm.isEmpty {
            hooks.removeValue(forKey: "PermissionRequest")
        } else {
            hooks["PermissionRequest"] = perm
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        guard writeJSON(root, to: p) else {
            AtomicConfigWriter.discardScript(staged)   // 配置没写成，脚本也不落位
            return false
        }
        if on {
            return AtomicConfigWriter.commitScript(from: staged!, to: paths.claudeScript)
        }
        try? fm.removeItem(atPath: paths.claudeScript)   // 配置改成功后才删脚本
        cleanupBusyScriptIfUnused(paths)
        cleanupWaitScriptIfUnused(paths)
        cleanupPermissionScriptIfUnused(paths)
        return true
    }

    // MARK: - Kimi Code（~/.kimi-code/config.toml 的 [[hooks]] Stop 事件）

    private static func kimiScriptMarker(_ paths: GlowHookPaths) -> String {
        (paths.kimiScript as NSString).lastPathComponent
    }

    /// 写进 config.toml 的整行 command（纯函数，可单测）。路径必须再套一层 shell 引号：
    /// Kimi 用 `spawn(command, [], { shell: true })` 执行，整串交给 shell 解析，而脚本躺在
    /// 「Application Support」里——裸路径会被空格切断成两截（sh: /Users/…/Library/Application:
    /// No such file），hook 静默失败、完成提醒就此失灵，且日志里什么都不留。
    /// 外层用 TOML 单引号（literal 串，不做转义），内层双引号原样落到 shell 手里。
    /// Claude / Codex / Grok 三家的 command 早已带引号，只有这里漏了
    /// `argument` 供开工脚本传来源（四家共用一个脚本，靠 $1 区分）
    nonisolated static func kimiHookCommandLine(for script: String,
                                                argument: String? = nil) -> String {
        let arg = argument.map { " \($0)" } ?? ""
        return "command = '\"\(script)\"\(arg)'"
    }

    private static func isKimiInstalled(_ paths: GlowHookPaths) -> Bool {
        guard let toml = try? String(contentsOfFile: paths.kimiConfig, encoding: .utf8) else { return false }
        return toml.contains(kimiScriptMarker(paths))
            && FileManager.default.fileExists(atPath: paths.kimiScript)
    }

    @discardableResult
    private static func setKimiInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let fm = FileManager.default
        // 没装 Kimi Code（config.toml 不存在）就无法接入
        guard fm.fileExists(atPath: paths.kimiConfig),
              let toml = try? String(contentsOfFile: paths.kimiConfig, encoding: .utf8) else { return false }
        let commandLine = kimiHookCommandLine(for: paths.kimiScript)
        let busyLine = kimiHookCommandLine(for: paths.busyScript, argument: "kimi")
        let waitLine = kimiHookCommandLine(for: paths.waitScript, argument: "kimi")
        let installed = toml.contains(kimiScriptMarker(paths))

        if on {
            guard let token = GlowHookToken.ensure(paths) else { return false }
            // 幂等：已接入、三个脚本都最新、且配置已是当前格式（带边界标记、三条 hook 都在）→ 不动文件。
            // 必须连配置行一起验——只验脚本的话，早期写成裸路径的用户永远修不好
            if installed, fm.fileExists(atPath: paths.kimiScript),
               scriptIsCurrent(paths.kimiScript, token: token),
               scriptIsCurrent(paths.busyScript, token: token),
               scriptIsCurrent(paths.waitScript, token: token),
               toml.contains(commandLine), toml.contains(busyLine), toml.contains(waitLine),
               toml.contains(KimiHookBlock.beginMarker) { return true }

            // 已有引用但不是当前格式 → 先精确摘掉旧的，摘不干净就整笔放弃
            var base = toml
            if installed {
                switch KimiHookBlock.remove(from: toml, scriptPath: paths.kimiScript) {
                case .removed(let cleaned): base = cleaned
                case .notPresent:          break
                case .ambiguous:           return false
                }
            }
            guard let staged = AtomicConfigWriter.stageScript(
                    stdinNotifyScript(source: "kimi", token: token),
                    finalPath: paths.kimiScript) else { return false }
            guard ensureBusyScript(token: token, paths), ensureWaitScript(token: token, paths) else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            AtomicConfigWriter.backup(paths.kimiConfig)
            let block = KimiHookBlock.render(commandLine: commandLine, busyCommandLine: busyLine,
                                             waitCommandLine: waitLine)
            let newToml = base.hasSuffix("\n") ? base + "\n" + block + "\n" : base + "\n\n" + block + "\n"
            let result = AtomicConfigWriter.write(newToml, to: paths.kimiConfig) { text in
                // 结构校验：写出去的必须能再被自己摘回来，否则说明拼错了
                text.contains(KimiHookBlock.beginMarker) && text.contains(KimiHookBlock.endMarker)
                    && text.contains(commandLine) && text.contains(busyLine)
                    && text.contains(waitLine)
            }
            guard result.isSuccess else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            return AtomicConfigWriter.commitScript(from: staged, to: paths.kimiScript)
        }

        // 卸载
        switch KimiHookBlock.remove(from: toml, scriptPath: paths.kimiScript) {
        case .notPresent:
            try? fm.removeItem(atPath: paths.kimiScript)   // 残留脚本顺手清掉
            cleanupBusyScriptIfUnused(paths)
            cleanupWaitScriptIfUnused(paths)
            return true
        case .ambiguous:
            return false                                   // 定位不了就不动，宁可让用户手删
        case .removed(let cleaned):
            AtomicConfigWriter.backup(paths.kimiConfig)
            let result = AtomicConfigWriter.write(cleaned, to: paths.kimiConfig) { text in
                !text.contains(kimiScriptMarker(paths))
            }
            guard result.isSuccess else { return false }
            try? fm.removeItem(atPath: paths.kimiScript)
            cleanupBusyScriptIfUnused(paths)
            cleanupWaitScriptIfUnused(paths)
            return true
        }
    }

    // MARK: - Grok CLI（~/.grok/hooks/pronotch.json 独立钩子文件，Stop 事件 Claude 同构）

    private static func isGrokInstalled(_ paths: GlowHookPaths) -> Bool {
        FileManager.default.fileExists(atPath: paths.grokHookFile)
            && FileManager.default.fileExists(atPath: paths.grokScript)
    }

    @discardableResult
    private static func setGrokInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let fm = FileManager.default
        // 没装 Grok CLI（~/.grok 不存在）就无法接入
        guard fm.fileExists(atPath: paths.grokHome) else { return false }

        if on {
            guard let token = GlowHookToken.ensure(paths) else { return false }
            // 幂等：钩子文件在 + 两个脚本都最新 → 不动文件
            if isGrokInstalled(paths), scriptIsCurrent(paths.grokScript, token: token),
               scriptIsCurrent(paths.busyScript, token: token) { return true }
            guard let staged = AtomicConfigWriter.stageScript(
                    stdinNotifyScript(source: "grok", token: token),
                    finalPath: paths.grokScript) else { return false }
            guard ensureBusyScript(token: token, paths) else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            try? fm.createDirectory(atPath: paths.grokHooksDir, withIntermediateDirectories: true)
            // 路径含空格（Application Support），command 经 shell 解释，须引号包裹
            let root: [String: Any] = ["hooks": [
                "Stop": [["hooks": [["type": "command", "command": "\"\(paths.grokScript)\""]]]],
                "UserPromptSubmit": [["hooks": [["type": "command",
                                                 "command": busyCommand(paths, source: "grok")]]]]
            ]]
            guard writeJSON(root, to: paths.grokHookFile) else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            return AtomicConfigWriter.commitScript(from: staged, to: paths.grokScript)
        }
        // pronotch.json 整个文件都是我们写的：直接删即还原（不碰别家的钩子文件）
        try? fm.removeItem(atPath: paths.grokHookFile)
        try? fm.removeItem(atPath: paths.grokScript)
        cleanupBusyScriptIfUnused(paths)
        return true
    }

    // MARK: - Codex（config.toml 的 notify 转发器）

    /// 脚本文件名，用于在 notify 串里识别「是否引用了我们」——文件名不含斜杠，
    /// 无论路径在 TOML 里是否被转义（computer-use 套壳时会 JSON 转义斜杠）都能匹配。
    private static func codexScriptMarker(_ paths: GlowHookPaths) -> String {
        (paths.codexScript as NSString).lastPathComponent
    }

    private static func isCodexInstalled(_ paths: GlowHookPaths) -> Bool {
        guard let toml = try? String(contentsOfFile: paths.codexConfig, encoding: .utf8),
              let match = CodexNotifyParser.find(in: toml) else { return false }
        // notify 链中引用了我们的转发脚本（直接指向，或被 computer-use 等套在外层），且脚本在 → 已接入。
        // 旧版只认「首元素 = 脚本」，被套壳就误判「未接入」→ 重新勾选时酿成自引用死循环（光晕狂闪）。
        return match.rawValue.contains(codexScriptMarker(paths))
            && FileManager.default.fileExists(atPath: paths.codexScript)
    }

    /// Codex 的开工信号单走 `~/.codex/hooks.json`（Claude 同构 schema）。
    ///
    /// 之所以不跟完成提醒同路：完成走 `config.toml` 的 `notify`，那条链上压根没有「开始」事件。
    /// hooks.json 确实被 Codex 执行——ProNotch 早期版本往这里挂过 Stop，后来正是因为它
    /// **真的触发了**（多发一个无 host 的完成信号）才写了 `cleanCodexHooksOrphan` 去清；
    /// 机内 confirmo 与 vibe-island 也都在此注册 UserPromptSubmit。
    ///
    /// 注意 `cleanCodexHooksOrphan` 只删 Stop 下含 `pronotch://done` 的条目，
    /// 本条挂在 UserPromptSubmit 且特征串是 `busy`，不会被它误清。
    @discardableResult
    private static func setCodexBusy(_ on: Bool, token: String?, _ paths: GlowHookPaths) -> Bool {
        let p = paths.codexHooks
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: p) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            root = obj
        } else if !on {
            return true   // 文件都不存在，卸载无事可做
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var prompt = hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
        let ours = prompt.filter(entryIsOurBusy)

        if on {
            guard let token else { return false }
            if ours.count == 1, scriptIsCurrent(paths.busyScript, token: token) { return true }
            guard ensureBusyScript(token: token, paths) else { return false }
            prompt.removeAll(where: entryIsOurBusy)
            prompt.append(["hooks": [["type": "command",
                                      "command": busyCommand(paths, source: "codex"),
                                      "timeout": 5]]])
        } else {
            if ours.isEmpty { return true }
            prompt.removeAll(where: entryIsOurBusy)
        }

        AtomicConfigWriter.backup(p)
        if prompt.isEmpty {
            hooks.removeValue(forKey: "UserPromptSubmit")
        } else {
            hooks["UserPromptSubmit"] = prompt
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return writeJSON(root, to: p)
    }

    @discardableResult
    private static func setCodexInstalled(_ on: Bool, _ paths: GlowHookPaths) -> Bool {
        let fm = FileManager.default
        // 没装 Codex（config.toml 所在目录不存在）就无法接入
        guard fm.fileExists(atPath: paths.codexDir) else { return false }
        let toml = (try? String(contentsOfFile: paths.codexConfig, encoding: .utf8)) ?? ""

        let raw = CodexNotifyParser.find(in: toml)?.rawValue
        // notify 首元素就是我们的脚本
        let directlyOurs = CodexNotifyParser.parseStringArray(raw ?? "")?.first == paths.codexScript
        // 链中引用了我们（含被外层套壳）
        let inChain = raw?.contains(codexScriptMarker(paths)) == true

        if on {
            guard let token = GlowHookToken.ensure(paths) else { return false }
            // 开工信号是槽位显示用的附属能力，走的还是另一个文件。
            // 它失败不该把「完成提醒」这个主功能一起判失败——顶多槽位不亮，提醒照常
            setCodexBusy(true, token: token, paths)
            if inChain {
                // 已在 notify 链中。被 computer-use 等套在外层时，我们是「下游」，本就不该再向下转发；
                // 直接指向时，previous 取脚本自己记录的原值。绝不把「含我们自己的当前链」抓来当 previous，
                // 否则 exec 回自己 → 无限循环（这正是闪烁 bug 的根源）。脚本缺失或格式过期才重写。
                if !fm.fileExists(atPath: paths.codexScript)
                    || !scriptIsCurrent(paths.codexScript, token: token) {
                    let prev = directlyOurs ? readPreviousFromForwarder(paths) : nil
                    guard let staged = stageForwarder(previous: prev, token: token, paths) else { return false }
                    return AtomicConfigWriter.commitScript(from: staged, to: paths.codexScript)
                }
                return true
            }
            // 全新接入：当前 notify（不含我们）整体作为 previous 透传
            guard let staged = stageForwarder(previous: raw, token: token, paths) else { return false }
            AtomicConfigWriter.backup(paths.codexConfig)
            let newToml = CodexNotifyParser.upsert(toml, value: "[\"\(paths.codexScript)\"]")
            let result = AtomicConfigWriter.write(newToml, to: paths.codexConfig) { text in
                // 结构校验：改完必须还能被解析出唯一顶层 notify，且指向我们
                guard let m = CodexNotifyParser.find(in: text) else { return false }
                return CodexNotifyParser.parseStringArray(m.rawValue)?.first == paths.codexScript
            }
            guard result.isSuccess else {
                AtomicConfigWriter.discardScript(staged)
                return false
            }
            return AtomicConfigWriter.commitScript(from: staged, to: paths.codexScript)
        }

        setCodexBusy(false, token: nil, paths)
        if !inChain {
            cleanupBusyScriptIfUnused(paths)
            return true
        }
        if directlyOurs {
            // notify 直接是我们：还原原 notify（或删整条）+ 删脚本
            AtomicConfigWriter.backup(paths.codexConfig)
            let prev = readPreviousFromForwarder(paths)
            let newToml = (prev?.isEmpty == false)
                ? CodexNotifyParser.upsert(toml, value: prev!)
                : CodexNotifyParser.remove(toml)
            let result = AtomicConfigWriter.write(newToml, to: paths.codexConfig) { text in
                CodexNotifyParser.find(in: text)?.rawValue.contains(codexScriptMarker(paths)) != true
            }
            guard result.isSuccess else { return false }
            try? fm.removeItem(atPath: paths.codexScript)
            cleanupBusyScriptIfUnused(paths)
            return true
        }
        // 被外层套壳：notify 归上游（computer-use 等）管，不动它；只删我们的脚本即可
        // （上游转发到缺失脚本无害，不会再点亮光晕）。
        try? fm.removeItem(atPath: paths.codexScript)
        cleanupBusyScriptIfUnused(paths)
        return true
    }

    // MARK: - 转发脚本生成 / 解析

    /// 生成转发脚本并暂存：点亮光晕 + 透传 previous；原 notify 以 base64 存进脚本头供还原
    private static func stageForwarder(previous: String?, token: String,
                                       _ paths: GlowHookPaths) -> String? {
        // 根部兜底防自引用死循环：previous 绝不能（间接）引用本脚本，否则 exec 回自己 → 无限循环。
        // 被 computer-use 套壳后原 notify 链里就含我们，这里统一剥掉，任何调用路径都断得了环。
        let previous = (previous?.contains(codexScriptMarker(paths)) == true) ? nil : previous
        let prevB64 = previous?.data(using: .utf8)?.base64EncodedString() ?? ""
        let script = """
        #!/bin/bash
        # ProNotch · Codex 完成提醒转发器（自动生成，勿手改）· PRONOTCH_FMT=\(scriptFormat)
        # 还原：把 ~/.codex/config.toml 的 notify 改回下面 base64 的解码值，再删除本文件。
        # PRONOTCH_PREV_B64=\(prevB64)
        \(hostDetectSnippet)
        payload="$1"
        case "$payload" in
          *agent-turn-complete*)
            # 跳过 Codex Desktop 自动生成会话标题的内部任务——它在你刚发消息时就完成，会让光晕「一开始就亮」
            case "$payload" in
              *"Generate a concise UI title"*) : ;;
              *)
                host=$(detect_host)
                tid=$(printf '%s' "$payload" | sed -n 's/.*"thread-id"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -1)
                url="pronotch://done?source=codex&token=\(token)"
                [ -n "$host" ] && url="$url&host=$host"
                [ -n "$tid" ] && url="$url&session=$tid"
                \(deliverGuard) ;;
            esac ;;
        esac
        \(forwardExecBlock(previous: previous))
        """
        return AtomicConfigWriter.stageScript(script, finalPath: paths.codexScript)
    }

    /// 透传块：把原 notify 数组解析成 bash 参数 exec；无 previous 则空操作
    private static func forwardExecBlock(previous: String?) -> String {
        guard let previous, let elems = CodexNotifyParser.parseStringArray(previous),
              !elems.isEmpty else {
            return "# 原本无 notify，到此结束"
        }
        let quoted = elems.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        return "exec \(quoted) \"$payload\""
    }

    /// 从脚本头 `# PRONOTCH_PREV_B64=` 取回原 notify 数组串
    private static func readPreviousFromForwarder(_ paths: GlowHookPaths) -> String? {
        guard let script = try? String(contentsOfFile: paths.codexScript, encoding: .utf8) else { return nil }
        for line in script.split(separator: "\n") {
            if let r = line.range(of: "# PRONOTCH_PREV_B64=") {
                let b64 = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if b64.isEmpty { return nil }
                return Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
            }
        }
        return nil
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
