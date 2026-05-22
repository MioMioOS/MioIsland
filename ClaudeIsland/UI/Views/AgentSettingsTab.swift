//
//  AgentSettingsTab.swift
//  ClaudeIsland
//
//  Mio Agent settings tab — status monitoring, install/start/stop controls,
//  and unavailable-capability rows for features pending Phase 2 IPC.
//
//  Phase 1 scope (task #70):
//  - Status card: binary presence, process health, health endpoint ping
//  - Controls card: Install / Start / Stop buttons via launchctl
//  - Unavailable rows: Action execution, Workroom, Log streaming, SMAppService upgrade
//
//  Phase 2 (tracked separately): IPC socket, real-time status, Workroom binding.
//

import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Agent Status

private enum AgentStatus: Equatable {
    case checking
    case notInstalled   // ~/.mio/bin/mio-agent doesn't exist
    case stopped        // binary present, not running
    case running        // process alive + health endpoint reachable
    case unhealthy      // process found but health endpoint timeout/error

    var dotColor: Color {
        switch self {
        case .checking:     return Theme.neutralDot
        case .notInstalled: return Theme.neutralDot
        case .stopped:      return Theme.warning
        case .running:      return Theme.success
        case .unhealthy:    return Theme.error
        }
    }

    var label: String {
        switch self {
        case .checking:     return "检测中…"
        case .notInstalled: return "未安装"
        case .stopped:      return "已停止"
        case .running:      return "运行中"
        case .unhealthy:    return "进程存在但健康检测失败"
        }
    }
}

// MARK: - AgentSettingsTab

struct AgentSettingsTab: View {
    @State private var status: AgentStatus = .checking
    @State private var binaryExists = false
    @State private var processRunning = false
    @State private var healthReachable = false
    @State private var actionInProgress = false
    @State private var lastActionMessage: String? = nil

    // Known paths — Phase 2 may make these configurable
    private let binaryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/bin/mio-agent").path
    private let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/io.miomioos.mio-agent.plist").path
    private let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/agent.sock").path
    private let healthURL = URL(string: "http://127.0.0.1:7878")!
    private let launchLabel = "io.miomioos.mio-agent"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header description
            Text(L10n.isChinese
                 ? "Mio Agent 是在本机后台运行的守护进程，负责与 AI runtime 通信、执行 action 并上报结果。"
                 : "Mio Agent is a background daemon that communicates with AI runtimes, fires actions, and reports results to MioServer.")
                .font(.system(size: 11))
                .foregroundColor(Theme.subtle)

            // MARK: Status card
            SectionLabel(L10n.isChinese ? "状态" : "Status")
            SettingsCard {
                statusRow(
                    icon: "cpu",
                    title: L10n.isChinese ? "守护进程二进制" : "Daemon binary",
                    ok: binaryExists ? true : false,
                    detail: binaryExists ? binaryPath : (L10n.isChinese ? "未找到 — 请先安装" : "Not found — install first")
                )
                statusRow(
                    icon: "bolt.fill",
                    title: L10n.isChinese ? "进程状态" : "Process",
                    ok: processRunning ? true : (binaryExists ? false : nil),
                    detail: processRunning
                        ? (L10n.isChinese ? "运行中" : "Running")
                        : (L10n.isChinese ? "未运行" : "Not running")
                )
                statusRow(
                    icon: "heart.fill",
                    title: L10n.isChinese ? "健康端点" : "Health endpoint",
                    ok: healthReachable ? true : (processRunning ? false : nil),
                    detail: healthReachable
                        ? "127.0.0.1:7878 ✓"
                        : (L10n.isChinese ? "不可达" : "Unreachable")
                )
            }

            // MARK: Controls card
            SectionLabel(L10n.isChinese ? "控制" : "Controls")
            SettingsCard {
                HStack(spacing: 8) {
                    // Install button — only relevant when binary is absent
                    controlButton(
                        label: L10n.isChinese ? "安装" : "Install",
                        icon: "arrow.down.circle.fill",
                        enabled: !binaryExists && !actionInProgress
                    ) { await installAgent() }

                    // Start / Stop toggle
                    if processRunning {
                        controlButton(
                            label: L10n.isChinese ? "停止" : "Stop",
                            icon: "stop.fill",
                            enabled: binaryExists && !actionInProgress,
                            destructive: true
                        ) { await stopAgent() }
                    } else {
                        controlButton(
                            label: L10n.isChinese ? "启动" : "Start",
                            icon: "play.fill",
                            enabled: binaryExists && !actionInProgress
                        ) { await startAgent() }
                    }

                    // Refresh status
                    Button {
                        Task { await refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.subtle)
                    }
                    .buttonStyle(.plain)
                    .disabled(actionInProgress)
                }

                if let msg = lastActionMessage {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.subtle)
                        .padding(.top, 2)
                }
            }

            // MARK: Unavailable capabilities
            SectionLabel(L10n.isChinese ? "能力（待实现）" : "Capabilities (coming soon)")
            SettingsListCard {
                unavailableRow(
                    icon: "bolt.horizontal.fill",
                    label: L10n.isChinese ? "Action 执行" : "Action execution",
                    sublabel: L10n.isChinese
                        ? "需要 Phase 2 IPC — runtime adapter 对接"
                        : "Requires Phase 2 IPC — runtime adapter integration"
                )
                unavailableRow(
                    icon: "rectangle.3.group.fill",
                    label: L10n.isChinese ? "Workroom 绑定" : "Workroom binding",
                    sublabel: L10n.isChinese
                        ? "需要 MioServer 人工 auth cursor"
                        : "Requires MioServer human-auth cursor"
                )
                unavailableRow(
                    icon: "list.bullet.rectangle.fill",
                    label: L10n.isChinese ? "日志 streaming" : "Log streaming",
                    sublabel: L10n.isChinese
                        ? "需要 IPC socket 接入"
                        : "Requires IPC socket integration"
                )
                unavailableRow(
                    icon: "arrow.up.circle.fill",
                    label: L10n.isChinese ? "自动升级（SMAppService）" : "Auto-upgrade (SMAppService)",
                    sublabel: L10n.isChinese
                        ? "需要 upgrade.ts re-register 机制"
                        : "Requires upgrade.ts re-register mechanism",
                    isLast: true
                )
            }
        }
        .task { await refreshStatus() }
    }

    // MARK: - Status row (reuse CmuxConnectionTab pattern)

    @ViewBuilder
    private func statusRow(icon: String, title: String, ok: Bool?, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Theme.subtleStrong)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.detailText.opacity(0.9))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Circle()
                .fill(dotColor(ok))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }

    private func dotColor(_ ok: Bool?) -> Color {
        switch ok {
        case .some(true):  return Theme.success
        case .some(false): return Theme.error
        case .none:        return Theme.neutralDot
        }
    }

    // MARK: - Control button

    @ViewBuilder
    private func controlButton(
        label: String,
        icon: String,
        enabled: Bool,
        destructive: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(destructive ? Theme.destructiveText : Theme.backgroundInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(destructive ? Theme.destructiveFill : Theme.accent)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(destructive ? Theme.destructiveBorder : Color.clear, lineWidth: 0.5)
            )
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Unavailable row

    @ViewBuilder
    private func unavailableRow(
        icon: String,
        label: String,
        sublabel: String,
        isLast: Bool = false
    ) -> some View {
        SettingRow(icon: icon, label: label, sublabel: sublabel, isLast: isLast) {
            Text(L10n.isChinese ? "即将推出" : "Soon")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.subtle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Theme.controlFill)
                        .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 0.5))
                )
        }
        // Dim unavailable rows to signal non-interactive state
        .opacity(0.55)
    }

    // MARK: - Status probe

    private func refreshStatus() async {
        // Binary presence
        let binExists = FileManager.default.fileExists(atPath: binaryPath)

        // Process check via pgrep
        let running = await shellCheck("pgrep", args: ["-x", "mio-agent"])

        // Health endpoint ping (500ms timeout)
        let healthy: Bool
        if running {
            healthy = await pingHealth()
        } else {
            healthy = false
        }

        await MainActor.run {
            binaryExists = binExists
            processRunning = running
            healthReachable = healthy

            if !binExists {
                status = .notInstalled
            } else if !running {
                status = .stopped
            } else if healthy {
                status = .running
            } else {
                status = .unhealthy
            }
        }
    }

    private func pingHealth() async -> Bool {
        do {
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 0.5
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Returns true if the shell command exits 0.
    private func shellCheck(_ cmd: String, args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [cmd] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Actions

    private func installAgent() async {
        await MainActor.run {
            actionInProgress = true
            lastActionMessage = L10n.isChinese ? "正在安装…" : "Installing…"
        }

        // Source: bundled binary in app Resources
        guard let srcPath = Bundle.main.path(forResource: "mio-agent", ofType: nil) else {
            await MainActor.run {
                lastActionMessage = L10n.isChinese
                    ? "错误：App bundle 中未找到 mio-agent 二进制"
                    : "Error: mio-agent binary not found in app bundle"
                actionInProgress = false
            }
            return
        }

        let mioDir = (binaryPath as NSString).deletingLastPathComponent
        let launchAgentsDir = (plistPath as NSString).deletingLastPathComponent

        do {
            // Create directories
            try FileManager.default.createDirectory(atPath: mioDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

            // Copy binary
            if FileManager.default.fileExists(atPath: binaryPath) {
                try FileManager.default.removeItem(atPath: binaryPath)
            }
            try FileManager.default.copyItem(atPath: srcPath, toPath: binaryPath)

            // Make executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)

            // Ad-hoc codesign (required for Keychain access on Apple Silicon)
            await shellRun("/usr/bin/codesign", args: ["--sign", "-", "--force", binaryPath])

            // Write LaunchAgent plist
            let plistContent = launchAgentPlist()
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)

            // Bootstrap with launchctl
            let uid = "\(getuid())"
            await shellRun("/bin/launchctl", args: ["bootstrap", "user/\(uid)", plistPath])

            await MainActor.run {
                lastActionMessage = L10n.isChinese ? "安装完成" : "Installed"
            }
        } catch {
            await MainActor.run {
                lastActionMessage = "Error: \(error.localizedDescription)"
            }
        }

        await refreshStatus()
        await MainActor.run { actionInProgress = false }
    }

    private func startAgent() async {
        await MainActor.run {
            actionInProgress = true
            lastActionMessage = L10n.isChinese ? "正在启动…" : "Starting…"
        }
        let uid = "\(getuid())"
        // Decide bootstrap vs kickstart based on whether the job is already loaded.
        //   - Loaded (job in launchd domain, process may be stopped/crashed) → `kickstart -k`
        //     to restart without re-registering the plist.
        //   - Not loaded (after bootout or first install) → `bootstrap` to register the plist.
        // This handles the edge case where the job is loaded but the process crashed:
        // `bootstrap` would fail with "service already loaded"; `kickstart -k` restarts it.
        if await isJobLoaded() {
            await shellRun("/bin/launchctl", args: ["kickstart", "-k", "user/\(uid)/\(launchLabel)"])
        } else {
            await shellRun("/bin/launchctl", args: ["bootstrap", "user/\(uid)", plistPath])
        }
        await refreshStatus()
        await MainActor.run {
            lastActionMessage = processRunning
                ? (L10n.isChinese ? "已启动" : "Started")
                : (L10n.isChinese ? "启动失败，请检查日志" : "Failed to start — check Logs tab")
            actionInProgress = false
        }
    }

    private func stopAgent() async {
        await MainActor.run {
            actionInProgress = true
            lastActionMessage = L10n.isChinese ? "正在停止…" : "Stopping…"
        }
        // Phase 2 IPC drain hook — currently a no-op.
        // Phase 2: replace with real IPC drain — send drain request via agent.sock,
        // wait for irreversible in-flight actions to reach transmission_complete or
        // needs_human before proceeding, with a hard deadline (spec: 8s / ExitTimeOut=15s).
        await requestDrain(deadlineMs: 8_000)

        // Use `bootout` to fully unload the job. `kill SIGTERM` does NOT stop a
        // KeepAlive job — launchd immediately restarts it after the process exits.
        let uid = "\(getuid())"
        await shellRun("/bin/launchctl", args: ["bootout", "user/\(uid)/\(launchLabel)"])
        await refreshStatus()
        await MainActor.run {
            lastActionMessage = processRunning
                ? (L10n.isChinese ? "进程仍在运行" : "Process still running")
                : (L10n.isChinese ? "已停止" : "Stopped")
            actionInProgress = false
        }
    }

    /// Check whether the LaunchAgent job is currently registered in the launchd user domain.
    ///
    /// Uses `launchctl list <label>` (exit 0 = loaded, non-zero = not found/error).
    /// Empirically verified on macOS: `list` reliably returns exit 0 for a loaded job and
    /// non-zero (e.g. 113) when the label is absent. `launchctl print user/<uid>/<label>`
    /// was tested and found to return exit 113 even for a loaded job in some shell contexts,
    /// so it is NOT used here despite appearing more domain-aware.
    ///
    /// Note: GUI app context (MioIsland launch) vs. shell context may differ. If behavior
    /// diverges, add an app-context smoke test when the install path is validated end-to-end.
    private func isJobLoaded() async -> Bool {
        await shellCheck("launchctl", args: ["list", launchLabel])
    }

    /// IPC drain stub — no-op in Phase 1.
    ///
    /// Phase 2 implementation: open a Unix socket connection to `socketPath` (agent.sock),
    /// send a drain request, and await acknowledgment that no irreversible actions are in-flight,
    /// or until `deadlineMs` elapses (whichever comes first). On deadline, proceed with bootout
    /// anyway — the agent's ExitTimeOut=15s provides a final safety window.
    private func requestDrain(deadlineMs: Int) async {
        // Phase 1: no IPC socket exists yet. Return immediately.
        // Phase 2: replace this body with real socket drain logic.
        _ = deadlineMs  // suppress unused-warning; parameter intentional for Phase 2 signature
    }

    @discardableResult
    private func shellRun(_ cmd: String, args: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    // MARK: - LaunchAgent plist

    private func launchAgentPlist() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ExitTimeOut</key>
            <integer>15</integer>
            <key>StandardOutPath</key>
            <string>\(home)/.mio/agent.log</string>
            <key>StandardErrorPath</key>
            <string>\(home)/.mio/agent.log</string>
        </dict>
        </plist>
        """
    }
}
