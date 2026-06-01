//
//  Localization.swift
//  ClaudeIsland
//
//  Simple i18n helper: auto-detects system locale and provides
//  English/Chinese translations for all user-visible strings.
//

import Foundation

enum L10n {
    /// Language options: "auto" (system), "en", "zh"
    static var appLanguage: String {
        get { UserDefaults.standard.string(forKey: "appLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "appLanguage") }
    }

    static var isChinese: Bool {
        switch appLanguage {
        case "zh": return true
        case "en": return false
        default: // "auto"
            let lang = Locale.current.language.languageCode?.identifier ?? "en"
            return lang == "zh"
        }
    }

    static var currentLanguageLabel: String {
        switch appLanguage {
        case "zh": return "中文"
        case "en": return "English"
        default: return isChinese ? "自动" : "Auto"
        }
    }

    static func tr(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }

    // Settings
    static var language: String { tr("Language", "语言") }

    // MARK: - Rate limit notification (RateLimitMonitor)

    static var rateLimitNotificationTitle: String {
        tr("Claude Code Usage Warning", "Claude Code 用量警告")
    }
    static func rateLimitNotificationBody(window: String, percent: Int) -> String {
        tr(
            "\(window) window usage has reached \(percent)%.",
            "\(window) 窗口用量已达 \(percent)%。"
        )
    }
    static func rateLimitNotificationBodyWithReset(window: String, percent: Int, resetHint: String) -> String {
        tr(
            "\(window) window usage has reached \(percent)%. Resets in \(resetHint).",
            "\(window) 窗口用量已达 \(percent)%，\(resetHint)后重置。"
        )
    }

    // MARK: - Short duration formatting (<1min / 5min / 1h23m / 3d)
    // Used by RateLimitMonitor to render "resets in X" hints.

    static var durationLessThanOneMinute: String {
        tr("<1min", "<1分钟")
    }
    static func durationMinutes(_ m: Int) -> String {
        tr("\(m)min", "\(m)分钟")
    }
    static func durationHoursMinutes(_ h: Int, _ m: Int) -> String {
        tr("\(h)h\(m)m", "\(h)小时\(m)分钟")
    }
    static func durationHours(_ h: Int) -> String {
        tr("\(h)h", "\(h)小时")
    }
    static func durationDays(_ d: Int) -> String {
        tr("\(d)d", "\(d)天")
    }

    // MARK: - Notch menu

    static var alertThreshold: String {
        tr("Alert", "警告阈值")
    }

    // MARK: - Chat processing indicator
    //
    // Note: the existing `working` entry below is "Working..." with a
    // trailing ellipsis (used in static labels). This new entry is bare
    // "Working" because ProcessingIndicatorView animates dots separately
    // on top of the base text.
    static var workingBaseLabel: String {
        tr("Working", "工作中")
    }

    // MARK: - Anthropic API Proxy (Settings → General)

    static var anthropicApiProxy: String {
        tr("Anthropic API Proxy", "Anthropic API 代理")
    }

    static var anthropicApiProxyPlaceholder: String {
        "http://127.0.0.1:7890"  // URL — no translation
    }

    /// Multi-paragraph help text under the Anthropic API Proxy field.
    /// Documents scope (what it covers) and non-coverage (what it doesn't).
    static var anthropicApiProxyDescription: String {
        tr(
            """
            Applies to: the rate-limit bar (api.anthropic.com) and every subprocess MioIsland spawns — including the Stats plugin's claude CLI and any future plugin's shell-outs. HTTPS_PROXY / HTTP_PROXY / ALL_PROXY are set once at startup, all children inherit automatically.

            Does NOT apply to: CodeLight sync (always direct) or third-party plugin URLSession calls (those use system proxy).

            Leave empty for direct connection.
            """,
            """
            作用于：刘海额度条 (api.anthropic.com) 和 MioIsland 启动的所有子进程，包括 Stats 插件的 claude CLI。启动时设置一次 HTTPS_PROXY / HTTP_PROXY / ALL_PROXY，子进程自动继承。

            不作用于：CodeLight 同步（始终直连）、第三方插件的 URLSession 调用（走系统代理）。

            留空即直连。
            """
        )
    }

    // MARK: - Session list

    static var sessions: String { tr("sessions", "个会话") }
    static var noSessions: String { tr("No sessions", "暂无会话") }
    static var runClaude: String { tr("Run claude in terminal", "在终端中运行 claude") }
    static var needsInput: String { tr("Needs your input", "需要你的输入") }
    static var you: String { tr("You:", "你：") }
    static var working: String { tr("Working...", "工作中...") }
    static var needsApproval: String { tr("Needs approval", "需要审批") }
    static var doneJump: String { tr("Done \u{2014} click to jump", "完成 \u{2014} 点击跳转") }
    static var compacting: String { tr("Compacting...", "压缩中...") }
    static var idle: String { tr("Idle", "空闲") }
    static var archived: String { tr("archived", "已归档") }
    static var active: String { tr("active", "活跃") }

    static func showAllSessions(_ count: Int) -> String { tr("Show all \(count) sessions", "显示全部 \(count) 个会话") }

    // MARK: - Menu

    static var back: String { tr("Back", "返回") }
    static var groupByProject: String { tr("Group by Project", "按项目分组") }
    static var pixelCatMode: String { tr("Pixel Cat Mode", "像素猫模式") }
    static var notchBuddyStyle: String { tr("Buddy Style", "Buddy 样式") }
    static var notchBuddyPixelCat: String { tr("Cat", "像素猫") }
    static var notchBuddyEmoji: String { tr("Emoji", "Emoji") }
    static var notchBuddyNeon: String { tr("Neon", "霓虹") }
    static var launchAtLogin: String { tr("Launch at Login", "开机启动") }
    static var hooks: String { tr("Hooks", "钩子") }
    // Hook diagnostics (Advanced tab)
    static var hookDiagTitle: String { tr("Hook Diagnostics", "Hook 诊断") }
    static var hookDiagSubtitle: String { tr("Inspect and repair Claude and Codex hook installation.", "检查并修复 Claude 与 Codex 的 hook 安装状态。") }
    static var hookDiagAgentClaude: String { tr("Claude Code", "Claude Code") }
    static var hookDiagAgentCodex: String { tr("Codex", "Codex") }
    static var hookDiagHealthy: String { tr("All good", "一切正常") }
    static var hookDiagDisabled: String { tr("Not enabled", "未启用") }
    static func hookDiagErrorCount(_ n: Int) -> String {
        isChinese ? "\(n) 个错误" : "\(n) error\(n == 1 ? "" : "s")"
    }
    static func hookDiagNoticeCount(_ n: Int) -> String {
        isChinese ? "\(n) 条提示" : "\(n) notice\(n == 1 ? "" : "s")"
    }
    static var hookDiagRecheck: String { tr("Re-check", "重新检查") }
    static var hookDiagReinstall: String { tr("Reinstall", "重新安装") }
    static var hookDiagUninstall: String { tr("Uninstall", "卸载") }
    static var hookDiagRepair: String { tr("Auto-repair", "一键修复") }
    static var hookDiagCleanupLegacy: String { tr("Clean up legacy hooks", "清理遗留 hooks") }
    static var hookDiagCleanupLegacyHint: String { tr("Remove leftover scripts and config entries from earlier app versions (Claude Island, Code Island).", "移除 Claude Island / Code Island 旧版本遗留的脚本与配置。") }
    static var hookDiagCodexDisabledHint: String { tr("Codex is turned off. Enable it in the General tab to install its hooks.", "Codex 未启用。请到「通用」标签打开后再安装 hook。") }
    static var hookDiagIssueScriptMissing: String { tr("Hook script file is missing", "Hook 脚本文件缺失") }
    static var hookDiagIssueScriptNotExecutable: String { tr("Hook script exists but is not executable", "Hook 脚本无执行权限") }
    static var hookDiagIssueConfigMalformed: String { tr("Config file contains invalid JSON", "配置文件 JSON 损坏") }
    static var hookDiagIssueStaleCommand: String { tr("Config references a script path that no longer exists", "配置指向的脚本路径已失效") }
    static var hookDiagIssueOtherHooks: String { tr("Other (non-CodeIsland) hooks also installed", "检测到其他非 CodeIsland 的 hook") }
    static var hookDiagIssueManifestMissing: String { tr("Install manifest file missing", "安装清单文件缺失") }
    static var hookDiagCleanupDone: String { tr("Legacy hooks cleaned.", "已清理遗留 hooks。") }
    static var hookDiagNothingToClean: String { tr("No legacy hooks found.", "没有遗留 hooks。") }
    static var codexSupport: String { tr("Codex Support", "Codex 支持") }
    static var codexNotifyOnComplete: String { tr("Codex Notifications", "Codex 通知") }
    static var accessibility: String { tr("Accessibility", "辅助功能") }
    static var version: String { tr("Version", "版本") }
    static var checkForUpdates: String { tr("Check for Updates", "检查更新") }
    static var autoCheckForUpdates: String { tr("Check for Updates Automatically", "自动检查更新") }
    static var autoCheckForUpdatesHint: String { tr("Turn off if you update via Homebrew", "通过 Homebrew 更新可关闭") }
    static var standby: String { tr("Standby", "待机中") }
    static var quit: String { tr("Quit", "退出") }
    static var on: String { tr("On", "开") }
    static var off: String { tr("Off", "关") }
    static var enable: String { tr("Enable", "启用") }
    static var enabled: String { tr("On", "已开启") }

    // MARK: - Completion Panel — phrase defaults
    static var qrPhraseContinue: String { tr("Continue", "继续") }
    static var qrPhraseOK: String { tr("OK", "好的") }
    static var qrPhraseExplain: String { tr("Explain more", "解释一下") }
    static var qrPhraseRetry: String { tr("Retry", "再试一次") }

    // MARK: - Completion Panel — UI strings
    static var qrSendFailed: String { tr("Failed to send — terminal unavailable", "发送失败，终端不可用") }
    static var qrGoToTerminal: String { tr("Go to terminal", "前往终端") }
    static func qrGoToTerminalNamed(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return qrGoToTerminal }
        return tr("Go to terminal · \(trimmed)", "前往终端 · \(trimmed)")
    }
    static var qrAcknowledge: String { tr("Got it", "知道了") }
    static var qrClose: String { tr("Close", "关闭") }
    static var qrReplyPlaceholder: String { tr("Reply directly…", "直接回复…") }
    static var qrSend: String { tr("Send", "发送") }
    static func subagentDoneBadge(_ n: Int) -> String { tr("\(n) subagents done", "\(n) 个 subagent 完成") }
    static var pendingToolAllow: String { tr("Allow", "允许") }
    static var pendingToolDeny: String { tr("Deny", "拒绝") }
    static func pendingToolAlwaysAllow(_ name: String) -> String { tr("Always Allow \(name)", "总是允许 \(name)") }
    static var pendingToolNeedsApproval: String { tr("Needs approval", "需授权") }
    static var pendingToolHighRiskHint: String { tr("High-risk operation — review diff in terminal", "高风险操作，请到终端查看 diff") }

    // MARK: - Completion Panel — QuickReplyPhrasesEditor
    static var qrEditorAdd: String { tr("Add phrase", "添加短语") }
    static var qrEditorReset: String { tr("Reset to defaults", "恢复默认") }
    static var qrEditorMaxHint: String { tr("Max 6 phrases", "最多 6 条") }
    static var qrEditorMinHint: String { tr("Keep at least one phrase", "至少保留一条") }
    static var qrEditorDeleteHint: String { tr("Delete", "删除") }
    static var qrEditorSectionTitle: String { tr("Quick Reply Phrases", "快速应答短语") }
    static var completionPanelEnabled: String { tr("Completion Panel", "任务完成面板") }

    // MARK: - Settings window
    static var systemSettings: String { tr("System Settings", "系统设置") }
    static var openSettings: String { tr("Settings", "设置") }
    static var tabGeneral: String { tr("General", "通用") }
    static var tabAppearance: String { tr("Appearance", "外观") }
    static var tabNotifications: String { tr("Notifications", "通知") }
    static var tabBehavior: String { tr("Behavior", "行为") }
    static var tabAdvanced: String { tr("Advanced", "高级") }
    static var tabAbout: String { tr("About", "关于") }
    static var tabPresets: String { tr("Launch Presets", "启动预设") }
    static var tabCodeLight: String { tr("CodeLight", "CodeLight") }
    static var tabCmuxConnection: String { tr("cmux Connection", "cmux 连接") }
    static var tabLogs: String { tr("Logs", "日志") }

    // cmux connection tab
    static var cmuxTabHeader: String { tr("Diagnose the relay between your iPhone and the terminal.", "诊断手机和终端之间的消息转发链路。") }
    static var cmuxBinaryRow: String { tr("cmux CLI", "cmux 命令行") }
    static var cmuxBinaryFound: String { tr("Found", "已找到") }
    static var cmuxBinaryMissing: String { tr("Not found (checked Homebrew, /Applications, ~/Applications)", "未找到（已检查 Homebrew、/Applications、~/Applications）") }
    static var accessibilityRowTitle: String { tr("Accessibility permission", "辅助功能权限") }
    static var accessibilityGranted: String { tr("Granted", "已授权") }
    static var accessibilityDenied: String { tr("Not granted — AppleScript relays will silently fail", "未授权 — AppleScript 转发会静默失败") }
    static var automationRowTitle: String { tr("Automation permission", "自动化权限") }
    static var automationUnknown: String { tr("Will be requested on next send", "下次发送时会请求") }
    static var runningClaudeCount: String { tr("Detected Claude sessions", "检测到的 Claude 会话数") }
    static var testSendButton: String { tr("Test send", "测试发送") }
    static var testSending: String { tr("Sending…", "发送中…") }
    static var testSendSuccess: String { tr("✓ Delivered", "✓ 已送达") }
    static var testSendNoTarget: String { tr("No cmux-hosted Claude session detected", "没有检测到 cmux 里的 Claude 会话") }
    static var testSendFailed: String { tr("Failed — check logs tab", "失败 — 请查看日志 tab") }
    static var openAccessibilitySettings: String { tr("Open Accessibility settings", "打开辅助功能设置") }
    static var openAutomationSettings: String { tr("Open Automation settings", "打开自动化设置") }
    static var repairPermission: String { tr("Repair", "修复权限") }
    static var repairing: String { tr("Repairing…", "修复中…") }
    static var repairAccessibilityPermission: String { tr("Repair Accessibility permission", "修复辅助功能权限") }
    static var repairAutomationPermission: String { tr("Repair Automation permission", "修复自动化权限") }
    static var refreshStatus: String { tr("Refresh", "刷新") }
    static var requestAutomationButton: String { tr("Request Automation permission", "请求自动化权限") }
    static var requestAutomationNoTerminal: String { tr("No supported terminal is running — start cmux/iTerm/Terminal first", "没有受支持的终端在运行 — 请先启动 cmux/iTerm/Terminal") }
    static var requestAutomationPrompted: String { tr("Dialog shown — approve it, then tap Refresh", "已触发弹窗 — 请同意后点刷新") }
    static var requestAutomationDenied: String { tr("Dialog denied or still missing permission", "弹窗被拒或权限仍缺失") }

    // logs tab
    static var logsHeader: String { tr("Real-time log output. Use this when submitting issues.", "实时日志输出。提交 issue 时请附上。") }
    static var logsCopyAll: String { tr("Copy all", "复制全部") }
    static var logsOpenFile: String { tr("Reveal file", "打开文件夹") }
    static var logsSubmitIssue: String { tr("Submit GitHub issue", "提交 GitHub issue") }
    static var logsCopied: String { tr("Copied", "已复制") }
    static var logsIssueClipboardNotice: String { tr("Full log copied to clipboard — paste below", "完整日志已复制到剪贴板 — 请粘贴到下方") }
    static var logsEmpty: String { tr("Log is empty. Interact with CodeIsland to generate entries.", "日志为空。操作 CodeIsland 会产生日志。") }
    static var pairedIPhones: String { tr("Paired iPhones", "已配对 iPhone") }
    static var pairNewPhone: String { tr("Pair New iPhone", "配对新 iPhone") }
    // Pair iPhone inline panel
    static var pairPanelOnline: String { tr("Online", "在线") }
    static var pairPanelNotConnected: String { tr("Not connected", "未连接") }
    static var pairPanelConnecting: String { tr("Connecting…", "连接中…") }
    static var pairPanelStepServerTitle: String { tr("Step 1 · Configure Server", "第 1 步 · 配置服务器") }
    static var pairPanelStepServerBody: String { tr("Set your CodeLight relay server. Your messages sync through it end-to-end encrypted — the server never sees plaintext. Without this step, the QR code cannot be generated.", "先设置一个 CodeLight 中继服务器。你的消息会通过它端到端加密同步 —— 服务端看不到明文。没配好这一步，下面的二维码不会生成。") }
    static var pairPanelServerPlaceholder: String { tr("https://your-server.example", "https://你的服务器.example") }
    static var pairPanelSaveAndConnect: String { tr("Save and Connect", "保存并连接") }
    static var pairPanelChangeServer: String { tr("Change Server", "更换服务器") }
    static var pairPanelCancel: String { tr("Cancel", "取消") }
    static var pairPanelSave: String { tr("Save", "保存") }
    static var pairPanelStoredLocally: String { tr("The server URL is stored locally and never leaves your Mac.", "服务器地址仅保存在本机，不会外发。") }
    static var pairPanelStepScanTitle: String { tr("Step 2 · Scan with Code Light", "第 2 步 · 用 Code Light 扫码") }
    static var pairPanelStepScanBody: String { tr("Open Code Light on iPhone and scan this QR, or enter the short code manually.", "在 iPhone 打开 Code Light，扫描下方二维码，或手动输入配对码。") }
    static var pairPanelShortCodeLabel: String { tr("Pairing Code", "配对码") }
    static var pairPanelGeneratingCode: String { tr("Generating pairing code…", "生成配对码中…") }
    static var pairPanelLinkedDevices: String { tr("Linked Devices", "已连接设备") }
    static var pairPanelChangeServerTooltip: String { tr("Change server URL", "更换服务器地址") }
    static var pairPanelServerLabel: String { tr("Server", "服务器") }
    static var pairPanelDeviceLabel: String { tr("This Mac", "本机") }
    static var pairPanelServerErrorPrefix: String { tr("Connection error:", "连接错误：") }

    // MARK: - Redeem code (Pair Phone redemption flow)
    //
    // Mirrors the server contract for /v1/pairing/redeem-code. Mac is
    // the redemption point now (Apple 3.1.1 forced this off iOS); the
    // iPhone inherits trial status via DeviceLink at pair time.

    static var redeemSectionTitle: String { tr("Have a redeem code?", "已有兑换码？") }
    static var redeemSectionSubtitle: String {
        tr("Activate the trial on this Mac. Paired iPhones inherit it automatically.",
           "在本 Mac 激活试用,配对的 iPhone 会自动继承。")
    }
    static var redeemPlaceholder: String { tr("FREE-XXXXXXXX", "FREE-XXXXXXXX") }
    static var redeemButton: String { tr("Activate", "激活") }
    static var redeemButtonSubmitting: String { tr("Activating…", "激活中…") }
    static var redeemDisabledOffline: String {
        tr("Connect to the server first to activate.", "请先连接服务器再激活。")
    }
    /// Hero copy for the post-redeem celebration overlay. Kept short so the
    /// confetti can carry the energy; longer detail rides on the days line
    /// below it.
    static var redeemSuccessTitle: String { tr("Activated!", "兑换成功!") }
    /// Subtitle on the celebration card — "+ N days of trial / 获得 N 天试用".
    /// Singular vs plural is handled per-locale: Chinese ignores plurals,
    /// English uses "day" only when N==1.
    static func redeemSuccessDays(_ d: Int) -> String {
        if L10n.isChinese {
            return "获得 \(d) 天试用"
        }
        return d == 1 ? "+1 day of trial" : "+\(d) days of trial"
    }
    /// Trial-active banner — "已激活(剩余 14 天)" to match iOS App's
    /// subscription row exactly. Short copy fits on one line in the
    /// 280pt popup card; expiry date is dropped (caller can show a
    /// tooltip / detail view if needed). All four banner states use
    /// the same compact 1-line pattern for visual consistency.
    static func subscriptionTrialBanner(daysLeft: Int) -> String {
        if L10n.isChinese {
            return "已激活(剩余 \(daysLeft) 天)"
        }
        return daysLeft == 1
            ? "Active (1 day left)"
            : "Active (\(daysLeft) days left)"
    }

    /// Lifetime/permanent subscription label.
    static var subscriptionActiveBanner: String {
        tr("Active", "已激活")
    }

    /// Trial expired. Banner is red; the redeem disclosure right below
    /// is the call-to-action — banner doesn't need to repeat the prompt.
    static var subscriptionExpiredBanner: String {
        tr("Expired", "已过期")
    }

    /// No active subscription. Shown when status is .none AND there's
    /// no recent local redemption record.
    static var subscriptionNoneBanner: String {
        tr("Not activated", "未激活")
    }

    static var subscriptionRefreshTooltip: String {
        tr("Refresh status", "刷新状态")
    }

    // Error messages — keys mirror the server's stable `error` field.
    static var redeemErrorUnauthorized: String {
        tr("Login expired. Reconnect the server and try again.",
           "登录态失效,请重新连接服务器后重试。")
    }
    static var redeemErrorNotAMac: String {
        tr("This device isn't recognised as a Mac. Contact support.",
           "本设备未被识别为 Mac,请联系客服。")
    }
    static var redeemErrorInvalidCode: String {
        tr("Redeem code is invalid.", "兑换码无效。")
    }
    static var redeemErrorCodeExhausted: String {
        tr("This code has been fully redeemed.", "兑换码已被领完。")
    }
    static var redeemErrorCodeExpired: String {
        tr("This code has expired.", "兑换码已过期。")
    }
    static var redeemErrorCodeRevoked: String {
        tr("This code has been revoked.", "此兑换码已被作废。")
    }
    static var redeemErrorAlreadyRedeemed: String {
        tr("This Mac already used this code.", "本 Mac 已使用过这张码。")
    }
    static var redeemErrorRateLimited: String {
        tr("Too many attempts. Please wait an hour and try again.",
           "失败次数过多,请稍后再试。")
    }
    static var redeemErrorServerError: String {
        tr("Server error. Please try again later.", "服务器繁忙,请稍后重试。")
    }
    static var redeemErrorNetwork: String {
        tr("Network error. Check your connection and try again.",
           "网络错误,请检查网络后重试。")
    }
    static var redeemErrorClientTooOld: String {
        tr("This version is too old. Please update to continue.",
           "当前版本过旧,请升级后继续使用。")
    }

    // MARK: - Upgrade-required alert (HTTP 426 client_too_old)

    static var upgradeRequiredTitle: String {
        tr("MioIsland update required", "需要升级 MioIsland")
    }
    /// Used only when the server response is missing a `message` field.
    /// Normally the server-sent message wins so admins can change copy
    /// (e.g. mention a specific version) without shipping a new Mac
    /// build. Kept version-agnostic so a stale fallback never lies
    /// about the required version.
    static var upgradeRequiredFallbackMessage: String {
        tr("The server requires a newer MioIsland or Code Light client to continue.",
           "服务器端要求最新版本的 MioIsland 或 Code Light 客户端才能继续使用。")
    }
    static var upgradeNow: String { tr("Update Now", "立即升级") }
    static var upgradeLater: String { tr("Later", "稍后") }
    static var launchPresetsSection: String { tr("Launch Presets", "启动预设") }
    static var addPreset: String { tr("New Preset", "新建预设") }
    static var noPresets: String { tr("No presets yet — tap + to add one", "还没有预设，点击 + 添加") }
    static var presetsHint: String { tr("Paired iPhones can launch these as new cmux sessions", "配对的 iPhone 可以用这些预设启动新的 cmux 会话") }
    static var behavior: String { tr("Behavior", "行为") }
    static var system: String { tr("System", "系统") }
    static var appearanceSection: String { tr("Appearance", "外观") }
    static var usageWarningThreshold: String { tr("Usage Warning", "用量警告") }
    static var clearEndedSessions: String { tr("Clear Ended Sessions", "清除已结束会话") }
    static var feedback: String { tr("Feedback", "反馈") }
    static var starOnGitHub: String { tr("Star on GitHub", "GitHub 点星") }
    static var wechatLabel: String { tr("WeChat", "微信") }
    static var maintainedTagline: String { tr("Actively maintained · Your star keeps us going!", "持续更新中 · Star 是我们最大的动力！") }
    static var quitApp: String { tr("Quit Mio Island", "退出 Mio Island") }

    // MARK: - Plugin marketplace
    static var pluginMarketplaceTitle: String { tr("Plugin Marketplace", "插件市场") }
    static var pluginMarketplaceDesc: String {
        tr("Discover themes, sounds, companions and utility plugins",
           "发现主题、音效、伙伴精灵和实用扩展")
    }
    static var pluginMarketplaceOpen: String { tr("Browse", "浏览市场") }

    // MARK: - Daily report
    static var yesterdayLabel: String { tr("Yesterday", "昨天") }
    static var turnsLabel: String { tr("Turns", "轮次") }
    static var focusLabel: String { tr("Focus", "专注时长") }
    static var linesLabel: String { tr("Lines", "代码行") }
    static var sessionsLabel: String { tr("Sessions", "会话") }
    static var projectsLabel: String { tr("Projects", "项目") }
    static var peakBurstLabel: String { tr("Peak", "最长专注") }
    static var filesLabel: String { tr("Files", "文件") }
    static var peakHourLabel: String { tr("Peak hour", "活跃时段") }
    static var topToolsHeader: String { tr("Top tools", "常用工具") }
    static var topSkillsHeader: String { tr("Top skills", "常用 Skills") }
    static var topMCPHeader: String { tr("MCP plugins", "MCP 调用") }
    static var primaryProjectHeader: String { tr("Primary project", "主要项目") }

    // Day / Week view switcher
    static var dayViewTab: String { tr("Day", "日") }
    static var weekViewTab: String { tr("Week", "周") }

    // Week view extras
    static var weekHighlightsHeader: String { tr("Week highlights", "本周高光") }
    static var streakLabel: String { tr("Streak", "连续天数") }
    static func streakDays(_ days: Int) -> String {
        tr(days == 1 ? "\(days) day" : "\(days) days", "\(days) 天")
    }
    static var vsLastWeekHeader: String { tr("vs. last week", "对比上周") }
    static func peakDayHighlight(_ weekdayName: String, turns: Int) -> String {
        tr("Peak day: \(weekdayName) · \(turns) turns",
           "峰值日: \(weekdayName) · \(turns) 轮")
    }
    static func peakBurstHighlight(_ weekdayName: String, minutes: String) -> String {
        tr("Longest focus: \(minutes) on \(weekdayName)",
           "最长专注: \(minutes)（\(weekdayName)）")
    }
    static func primaryProjectHighlight(_ project: String) -> String {
        tr("Main project: \(project)", "主要项目: \(project)")
    }
    static var noActivityThisWeek: String { tr("No activity this week yet.", "本周还没有活动") }
    static var sparklineLabel: String { tr("Daily focus", "每日专注") }
    /// Prefix for the sparkline normalization ceiling, e.g. "max 4h13m".
    static var sparklineMaxPrefix: String { tr("max", "最高") }

    // Hero card expand / collapse
    static var expandLabel: String { tr("Show more", "查看更多") }
    static var collapseLabel: String { tr("Show less", "收起") }

    // First-launch loading state
    static var analyzingTitle: String { tr("Crunching your numbers…", "正在统计你的数据…") }
    static var analyzingSubtitle: String {
        tr("Scanning the last 14 days of Claude activity. First launch takes a moment.",
           "扫描过去 14 天的 Claude 活动，首次启动稍等一下。")
    }

    static func dailyTaglineWeek(_ focus: String) -> String {
        tr("You worked with Claude for \(focus) this week — here's the recap.",
           "本周你和 Claude 协作了 \(focus) — 一周回顾")
    }
    /// Tagline under the header, filled with the focus duration.
    static func dailyTagline(_ focus: String) -> String {
        tr("You worked with Claude for \(focus) — here's the recap.",
           "你和 Claude 协作了 \(focus) — 昨日回顾")
    }
    static func focusHelperDesc(_ sessions: Int) -> String {
        tr("Active time across \(sessions) sessions (idle gaps excluded)",
           "跨 \(sessions) 个会话的活跃时长（不含空闲）")
    }

    // MARK: - Notch collapsed status

    static var approve: String { tr("approve", "审批") }
    static var done: String { tr("done", "完成") }

    // MARK: - Approval

    static var allow: String { tr("Allow", "允许") }
    static var deny: String { tr("Deny", "拒绝") }
    static var permissionRequest: String { tr("Permission Request", "权限请求") }
    static var goToTerminal: String { tr("Go to Terminal", "前往终端") }
    static var terminal: String { tr("Terminal", "终端") }

    // MARK: - Session state

    static var ended: String { tr("Ended", "已结束") }
    static var clearEnded: String { tr("Clear Ended", "清除已结束") }

    // MARK: - Sound settings

    static var soundSettings: String { tr("Sound Settings", "声音设置") }
    static var globalMute: String { tr("Global Mute", "全部静音") }
    static var eventSounds: String { tr("Event Sounds", "事件声音") }
    static var notificationSound: String { tr("Notification Sound", "通知声音") }
    static var screen: String { tr("Screen", "屏幕") }
    static var automatic: String { tr("Automatic", "自动") }
    static var auto_: String { tr("Auto", "自动") }
    static var builtIn: String { tr("Built-in", "内置") }
    static var main_: String { tr("Main", "主屏幕") }
    static var builtInOrMain: String { tr("Built-in or Main", "内置或主屏幕") }

    // MARK: - Sound events

    static var sessionStart: String { tr("Session Start", "会话开始") }
    static var processingBegins: String { tr("Processing Begins", "开始处理") }
    static var approvalGranted: String { tr("Approval Granted", "已批准") }
    static var approvalDenied: String { tr("Approval Denied", "已拒绝") }
    static var sessionComplete: String { tr("Session Complete", "会话完成") }
    static var error: String { tr("Error", "错误") }
    static var contextCompacting: String { tr("Context Compacting", "上下文压缩") }
    static var rateLimitWarning: String { tr("Usage Warning (90%)", "用量警告 (90%)") }

    // MARK: - Chat view

    static var loadingMessages: String { tr("Loading messages...", "加载消息中...") }
    static var noMessages: String { tr("No messages", "暂无消息") }
    static var processing: String { tr("Processing", "处理中") }
    static var claudeNeedsInput: String { tr("Claude Code needs your input", "Claude Code 需要你的输入") }
    static var interrupted: String { tr("Interrupted", "已中断") }
    static func newMessages(_ count: Int) -> String { tr("\(count) new messages", "\(count) 条新消息") }
    static func runningAgent(_ desc: String?) -> String {
        let d = desc ?? tr("Running agent...", "运行代理中...")
        return d
    }
    static var runningAgentDefault: String { tr("Running agent...", "运行代理中...") }
    static func waiting(_ desc: String) -> String { tr("Waiting: \(desc)", "等待中: \(desc)") }
    static func hiddenToolCalls(_ count: Int) -> String { tr("\(count) more tool calls", "还有 \(count) 个工具调用") }
    static func subagentTools(_ count: Int) -> String { tr("Subagent used \(count) tools:", "子代理使用了 \(count) 个工具：") }

    // MARK: - Tool result views

    static var userModified: String { tr("(user modified)", "(用户已修改)") }
    static var created: String { tr("Created", "已创建") }
    static var written: String { tr("Written", "已写入") }
    static func backgroundTask(_ id: String) -> String { tr("Background task: \(id)", "后台任务: \(id)") }
    static var stderrLabel: String { tr("Stderr:", "错误输出：") }
    static var noContent: String { tr("(no content)", "(无内容)") }
    static var noMatches: String { tr("No matches", "未找到匹配") }
    static func filesMatched(_ count: Int) -> String { tr("\(count) files matched", "\(count) 个文件有匹配") }
    static var noFiles: String { tr("No files found", "未找到文件") }
    static var moreTruncated: String { tr("... more (truncated)", "... 更多（已截断）") }
    static func tools(_ count: Int) -> String { tr("\(count) tools", "\(count) 个工具") }
    static var noResults: String { tr("No results found", "未找到结果") }
    static func moreResults(_ count: Int) -> String { tr("... \(count) more results", "... 还有 \(count) 个结果") }
    static func status(_ s: String) -> String { tr("Status: \(s)", "状态: \(s)") }
    static func exitCode(_ code: Int) -> String { tr("Exit code: \(code)", "退出码: \(code)") }
    static func shellKilled(_ id: String) -> String { tr("Shell \(id) killed", "Shell \(id) 已终止") }
    static var completed: String { tr("Completed", "已完成") }
    static func moreLines(_ count: Int) -> String { tr("... (\(count) more lines)", "... (\(count) 更多行)") }
    static func moreFiles(_ count: Int) -> String { tr("... \(count) more files", "... 还有 \(count) 个文件") }
    static func moreHunks(_ count: Int) -> String { tr("... \(count) more hunks", "... 还有 \(count) 个代码块") }

    // MARK: - Sound event display names (for SoundManager)

    static func soundEventName(_ event: String) -> String {
        switch event {
        case "session_start": return sessionStart
        case "processing_begins": return processingBegins
        case "needs_approval": return needsApproval
        case "approval_granted": return approvalGranted
        case "approval_denied": return approvalDenied
        case "session_complete": return sessionComplete
        case "error": return error
        case "compacting": return contextCompacting
        case "rate_limit_warning": return rateLimitWarning
        default: return event
        }
    }

    // MARK: - Sound settings preview tooltip

    static func previewSound(_ name: String) -> String { tr("Preview \(name) sound", "预览 \(name) 声音") }

    // MARK: - Notch view status text

    static func approveWhat(_ tool: String) -> String { tr("\(L10n.approve) \(tool)?", "\(L10n.approve) \(tool)?") }

    // MARK: - Smart interactions

    static var smartSuppression: String { tr("Smart Suppression", "智能抑制") }
    static var autoCollapseOnMouseLeave: String { tr("Auto-Collapse on Leave", "离开时自动收起") }
    static var compactCollapsed: String { tr("Compact Notch", "紧凑刘海") }
    // MARK: - Notch customization
    //
    // Deviation from spec: the spec (Section 4.5) lists these keys
    // for `Localizable.xcstrings`, but this project currently uses
    // the hand-rolled `L10n` helper (en + zh-Hans as Swift string
    // pairs). Strings added here follow the established pattern
    // and match the voice of surrounding entries. A future migration
    // to `.xcstrings` can pick them up mechanically from this file.

    static var notchSectionHeader: String { tr("Notch", "灵动岛") }
    static var notchTheme: String { tr("Theme", "主题") }
    // v2 theme line-up (2026-04-20): Classic + six themes designed via
    // Claude Design. Old names (paper, neonLime, cyber, mint, rosegold,
    // ocean, aurora, mocha, lavender, cherry) were dropped on reset.
    static var notchThemeClassic: String { tr("Classic", "经典") }
    static var notchThemeForest: String { tr("Forest", "森林") }
    static var notchThemeNeonTokyo: String { tr("Night Circuit", "夜行电路") }
    static var notchThemeSunset: String { tr("Sunset", "落日") }
    static var notchThemeRetroArcade: String { tr("Retro Arcade", "复古游戏机") }
    static var notchThemeHighContrast: String { tr("High Contrast", "高对比") }
    static var notchThemeSakura: String { tr("Pink Mist", "粉雾") }
    static var notchHoverSpeed: String { tr("Hover Speed", "展开速度") }
    static var notchHoverInstant: String { tr("Fast", "即时") }
    static var notchHoverNormal: String { tr("1s", "1秒") }
    static var notchHoverSlow: String { tr("2s", "2秒") }
    static var notchFontSize: String { tr("Font Size", "字号") }
    static var notchFontSmall: String { tr("S", "小") }
    static var notchFontDefault: String { tr("M", "中") }
    static var notchFontLarge: String { tr("L", "大") }
    static var notchFontXLarge: String { tr("XL", "特大") }
    static var notchFontSmallFull: String { tr("Small", "小") }
    static var notchFontDefaultFull: String { tr("Default", "默认") }
    static var notchFontLargeFull: String { tr("Large", "大") }
    static var notchFontXLargeFull: String { tr("Extra Large", "特大") }
    static var notchShowBuddy: String { tr("Show Buddy", "显示宠物") }
    static var notchShowUsageBar: String { tr("Show Usage Bar", "显示用量条") }

    // Usage bar display mode picker
    static var notchUsageBarDisplayMode: String { tr("Display Mode", "显示方式") }
    static var usageBarModeAuto: String { tr("Auto", "自动") }
    static var usageBarModeAlert: String { tr("Alert", "警戒") }
    static var usageBarModeCompact: String { tr("Compact", "紧凑") }
    static var usageBarModeTime: String { tr("Time", "时间") }
    static var usageBarModeAutoDescription: String {
        tr("< 60% Compact · ≥ 60% Alert · ≥ 80% Red Pulse",
           "< 60% 紧凑 · ≥ 60% 警戒 · ≥ 80% 红色脉冲")
    }
    static var usageBarModeAlertDescription: String {
        tr("Always show enlarged warning layout", "始终显示加粗警戒样式")
    }
    static var usageBarModeCompactDescription: String {
        tr("Information-dense, low attention", "信息密集，低打扰")
    }
    static var usageBarModeTimeDescription: String {
        tr("Emphasize remaining time + ring", "突出剩余时间 + 环形")
    }

    // Per-provider sub-toggles
    static var usageBarShowClaude: String { tr("Show Claude", "显示 Claude") }
    static var usageBarShowCodex: String { tr("Show Codex", "显示 Codex") }

    // Usage bar interaction hints
    static var usageBarTapToRefresh: String { tr("Tap to refresh", "点击立即刷新") }
    static var usageBarRefreshingHint: String { tr("Refreshing…", "刷新中…") }
    static var usageBarJustRefreshed: String { tr("Just updated", "已更新") }
    static var usageBarJustNow: String { tr("just now", "刚刚") }
    static var usageBarTimeUntil5h: String { tr("until 5h reset", "5h 重置") }
    static var usageBarTimeUntil7d: String { tr("until 7d reset", "7d 重置") }

    static var notchHardwareMode: String { tr("Hardware Notch", "硬件刘海") }
    static var notchHardwareAuto: String { tr("Auto", "自动") }
    static var notchHardwareForceVirtual: String { tr("Force Virtual", "强制虚拟") }
    static var notchCustomizeButton: String { tr("Customize Size & Position…", "自定义尺寸与位置…") }
    static var notchEditSave: String { tr("Save", "保存") }
    static var notchEditCancel: String { tr("Cancel", "取消") }
    static var notchEditNotchPreset: String { tr("Notch Preset", "贴合刘海") }
    static var notchEditDragMode: String { tr("Drag Mode", "拖动模式") }
    static var notchEditReset: String { tr("Reset", "复位") }
    static var notchEditPresetDisabledTooltip: String { tr("Your device doesn't have a hardware notch", "你的设备没有硬件刘海") }
    static func notchThemeName(_ id: NotchThemeID) -> String {
        switch id.rawValue {
        case NotchThemeID.classic.rawValue: return notchThemeClassic
        case NotchThemeID.forest.rawValue: return notchThemeForest
        case NotchThemeID.neonTokyo.rawValue: return notchThemeNeonTokyo
        case NotchThemeID.sunset.rawValue: return notchThemeSunset
        case NotchThemeID.retroArcade.rawValue: return notchThemeRetroArcade
        case NotchThemeID.highContrast.rawValue: return notchThemeHighContrast
        case NotchThemeID.sakura.rawValue: return notchThemeSakura
        default: return ThemeRegistry.shared.displayName(for: id)
        }
    }
}
