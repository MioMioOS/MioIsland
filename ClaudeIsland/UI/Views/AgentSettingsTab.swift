//
//  AgentSettingsTab.swift
//  ClaudeIsland
//
//  Mio Agent settings tab — Phase 2 state design implementation.
//
//  Phase 1 scope (#70/#74): Install/Start/Stop via launchctl + basic status probe.
//  Phase 2 scope (#93, spec #90): Full AgentLifecyclePhase state model, LaunchAgent
//    loaded detection, lifecycle detail rows, Logs card, honest Phase 1 stop copy.
//
//  State model: docs/productization/agent-tab-phase2-state-design.md
//
//  Phase 2 stubs (IPC drain, real-time status, log streaming): marked TODO(Phase2).
//

import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - AgentLifecyclePhase

/// Full state model per #90 spec §3.
///
/// Distinguishes binary presence, LaunchAgent registration, process running,
/// health endpoint availability, and transient busy states.
enum AgentLifecyclePhase: Equatable {
    case checking           // initial probe in progress
    case notInstalled       // ~/.mio/bin/mio-agent missing
    case installedUnloaded  // binary present, launchd job not loaded
    case loadedStopped      // job loaded, process not running
    case starting           // install/start command in progress
    case runningHealthy     // process running + health endpoint 200
    case runningUnhealthy   // process running, health endpoint unreachable
    case draining           // TODO(Phase2): IPC drain in progress
    case stopping           // bootout in progress
    case error              // controlled diagnostic — see snap.lastDiagnostic
    case unknown            // probe failed or data stale

    // MARK: Display

    var dotColor: Color {
        switch self {
        case .checking, .unknown:                return Theme.neutralDot
        case .notInstalled:                      return Theme.neutralDot
        case .installedUnloaded, .loadedStopped: return Theme.warning
        case .starting, .stopping, .draining:    return .blue
        case .runningHealthy:                    return Theme.success
        case .runningUnhealthy, .error:          return Theme.error
        }
    }

    var showSpinner: Bool {
        switch self {
        case .checking, .starting, .stopping, .draining: return true
        default: return false
        }
    }

    var primaryLabel: String {
        switch self {
        case .checking:          return "Checking…"
        case .notInstalled:      return "Not installed"
        case .installedUnloaded: return "Installed · stopped"
        case .loadedStopped:     return "Loaded · not running"
        case .starting:          return "Starting…"
        case .runningHealthy:    return "Running"
        case .runningUnhealthy:  return "Running · health check failed"
        case .draining:          return "Stopping safely…"
        case .stopping:          return "Stopping…"
        case .error:             return "Action failed"
        case .unknown:           return "Status unknown"
        }
    }

    var descriptionText: String {
        switch self {
        case .checking:
            return "Probing agent status…"
        case .notInstalled:
            return "Install the bundled mio-agent before starting local action execution."
        case .installedUnloaded:
            return "The LaunchAgent is not running. Start it to prepare local action execution."
        case .loadedStopped:
            return "The job is loaded but the process is not running. Start will kickstart the job."
        case .starting:
            return "Wait; controls are disabled while the agent starts."
        case .runningHealthy:
            return "mio-agent is available on this Mac."
        case .runningUnhealthy:
            return "The process exists, but the local health endpoint did not respond."
        case .draining:
            return "Waiting for in-flight actions to reach a safe stopping point."
        case .stopping:
            return "The agent will be unloaded from launchd. Drain-safe stop is coming in Phase 2."
        case .error:
            return ""   // diagnostic carried in snap.lastDiagnostic
        case .unknown:
            return "Could not determine agent status. Refresh to try again."
        }
    }

    /// True while a launchctl/install command is in flight.
    var isBusy: Bool {
        switch self {
        case .checking, .starting, .stopping, .draining: return true
        default: return false
        }
    }
}

// MARK: - AgentLifecycleSnapshot

/// Single view model passed through the UI.
struct AgentLifecycleSnapshot {
    var binaryExists: Bool = false
    var launchAgentLoaded: Bool? = nil  // nil = probe not run yet
    var processRunning: Bool = false
    var healthReachable: Bool = false
    var socketExists: Bool? = nil       // Phase 2: ~/.mio/agent.sock
    var logFileExists: Bool = false
    var phase: AgentLifecyclePhase = .checking
    var lastCheckedAt: Date? = nil
    var lastDiagnostic: String? = nil   // error/diagnostic copy (controlled)

    var isBusy: Bool { phase.isBusy }

    var lastCheckedLabel: String {
        guard let date = lastCheckedAt else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "Last checked \(fmt.string(from: date))"
    }
}

// MARK: - AgentSettingsTab

struct AgentSettingsTab: View {
    @State private var snap = AgentLifecycleSnapshot()

    // Known paths
    private let binaryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/bin/mio-agent").path
    private let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/io.miomioos.mio-agent.plist").path
    private let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/agent.sock").path
    private let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/agent.log").path
    private let healthURL = URL(string: "http://127.0.0.1:7878")!
    private let launchLabel = "io.miomioos.mio-agent"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Description
            Text("Mio Agent is a background daemon that communicates with AI runtimes, fires actions, and reports results to MioServer.")
                .font(.system(size: 11))
                .foregroundColor(Theme.subtle)

            // MARK: Overall status card
            overallStatusCard

            // MARK: Lifecycle detail rows
            SectionLabel("Lifecycle")
            lifecycleDetailRows

            // MARK: Controls
            SectionLabel("Controls")
            controlsCard

            // MARK: Logs card
            SectionLabel("Logs")
            logsCard

            // MARK: Upcoming capabilities
            SectionLabel("Capabilities (coming soon)")
            upcomingCapabilitiesCard
        }
        .task { await refreshStatus() }
    }

    // MARK: - Overall status card

    private var overallStatusCard: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 12) {
                // Dot / spinner
                if snap.phase.showSpinner {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                        .padding(.top, 2)
                } else {
                    Circle()
                        .fill(snap.phase.dotColor)
                        .frame(width: 10, height: 10)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(snap.phase.primaryLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.detailText)

                    let desc = snap.phase == .error
                        ? (snap.lastDiagnostic ?? "An error occurred.")
                        : snap.phase.descriptionText
                    if !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                // Last checked + refresh
                VStack(alignment: .trailing, spacing: 4) {
                    if !snap.lastCheckedLabel.isEmpty {
                        Text(snap.lastCheckedLabel)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.subtle)
                    }
                    Button {
                        Task { await refreshStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(snap.isBusy ? Theme.subtle.opacity(0.5) : Theme.subtle)
                    }
                    .buttonStyle(.plain)
                    .disabled(snap.isBusy)
                }
            }
        }
    }

    // MARK: - Lifecycle detail rows

    private var lifecycleDetailRows: some View {
        SettingsListCard {
            lifecycleRow(
                icon: "doc.fill",
                title: "Binary",
                path: binaryPath,
                state: snap.binaryExists ? ("Installed", Theme.success) : ("Missing", Theme.error)
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "gear",
                title: "LaunchAgent",
                path: launchLabel,
                state: {
                    switch snap.launchAgentLoaded {
                    case .some(true):  return ("Loaded", Theme.success)
                    case .some(false): return ("Unloaded", Theme.warning)
                    case .none:        return ("Unknown", Theme.neutralDot)
                    }
                }()
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "bolt.fill",
                title: "Process",
                path: "mio-agent",
                state: snap.processRunning
                    ? ("Running", Theme.success)
                    : ("Stopped", Theme.warning)
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "heart.fill",
                title: "Health",
                path: "127.0.0.1:7878",
                state: snap.healthReachable
                    ? ("OK", Theme.success)
                    : (snap.processRunning ? "Failed" : "Unavailable", snap.processRunning ? Theme.error : Theme.neutralDot)
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Socket",
                path: "~/.mio/agent.sock",
                state: ("Pending Phase 2", Theme.neutralDot),
                isLast: true
            )
        }
    }

    // MARK: - Controls card

    private var controlsCard: some View {
        SettingsCard {
            // Button row — visibility driven by phase
            HStack(spacing: 8) {
                // Install: shown when not installed
                if !snap.binaryExists {
                    accentButton(
                        label: "Install",
                        icon: "arrow.down.circle.fill",
                        enabled: !snap.isBusy
                    ) { await installAgent() }
                }

                // Start: shown when installed + not running
                if snap.binaryExists && !snap.processRunning
                    && snap.phase != .starting && snap.phase != .stopping {
                    accentButton(
                        label: "Start",
                        icon: "play.fill",
                        enabled: !snap.isBusy
                    ) { await startAgent() }
                }

                // Stop: shown when running or job loaded
                if snap.processRunning || snap.launchAgentLoaded == true {
                    if snap.phase != .starting && snap.phase != .stopping {
                        outlineButton(
                            label: "Stop",
                            icon: "stop.fill",
                            enabled: !snap.isBusy
                        ) { await stopAgent() }
                    }
                }

                // Refresh
                Button {
                    Task { await refreshStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(snap.isBusy ? Theme.subtle.opacity(0.5) : Theme.subtle)
                }
                .buttonStyle(.plain)
                .disabled(snap.isBusy)

                Spacer()
            }

            // Last action message / diagnostic
            if let diag = snap.lastDiagnostic {
                Text(diag)
                    .font(.system(size: 10))
                    .foregroundColor(snap.phase == .error ? Theme.error : Theme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Logs card

    private var logsCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use logs for install/start/stop diagnostics. Sensitive values are not expected here.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.subtle)

                HStack(spacing: 8) {
                    accentButton(label: "Open log file", icon: "doc.text", enabled: snap.logFileExists) {
                        openLogFile()
                    }
                    outlineButton(label: "Copy last 100 lines", icon: "doc.on.clipboard", enabled: snap.logFileExists) {
                        copyLastLinesOfLog(count: 100)
                    }
                }

                if !snap.logFileExists {
                    Text("No agent log yet. Start the agent to create ~/.mio/agent.log.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.subtle.opacity(0.7))
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Upcoming capabilities card

    private var upcomingCapabilitiesCard: some View {
        SettingsListCard {
            unavailableRow(
                icon: "bolt.horizontal.fill",
                label: "Action execution",
                sublabel: "Requires Phase 2 IPC — runtime adapter integration"
            )
            unavailableRow(
                icon: "rectangle.3.group.fill",
                label: "Workroom binding",
                sublabel: "Requires MioServer human-auth cursor"
            )
            unavailableRow(
                icon: "list.bullet.rectangle.fill",
                label: "Log streaming",
                sublabel: "Requires IPC socket integration"
            )
            unavailableRow(
                icon: "arrow.up.circle.fill",
                label: "Auto-upgrade (SMAppService)",
                sublabel: "Requires upgrade.ts re-register mechanism",
                isLast: true
            )
        }
    }

    // MARK: - View helpers

    @ViewBuilder
    private func lifecycleRow(
        icon: String,
        title: String,
        path: String,
        state: (String, Color),
        isLast: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Theme.subtleStrong)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.detailText.opacity(0.9))
                Text(path)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.subtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // State pill
            Text(state.0)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(state.1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(state.1.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func accentButton(
        label: String,
        icon: String,
        enabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(enabled ? Theme.backgroundInk : Theme.subtle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(enabled ? Theme.accent : Theme.controlFill)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func outlineButton(
        label: String,
        icon: String,
        enabled: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(enabled ? Theme.detailText.opacity(0.85) : Theme.subtle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.controlFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
                    )
            )
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func unavailableRow(
        icon: String,
        label: String,
        sublabel: String,
        isLast: Bool = false
    ) -> some View {
        SettingRow(icon: icon, label: label, sublabel: sublabel, isLast: isLast) {
            Text("Soon")
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
        .opacity(0.55)
    }

    // MARK: - Status probe

    private func refreshStatus() async {
        await MainActor.run { snap.phase = .checking }

        // Probe all fields concurrently where safe
        let fm = FileManager.default
        let binExists = fm.fileExists(atPath: binaryPath)
        let sockExists = fm.fileExists(atPath: socketPath)
        let logExists = fm.fileExists(atPath: logPath)

        // LaunchAgent loaded: `launchctl list <label>` exits 0 if the service is visible in the
        // current launchctl session domain. Install uses `bootstrap user/$(uid)` (the user domain),
        // not `gui/<uid>` (the GUI app domain) — these are distinct launchd domains in modern macOS.
        // TODO(#79 smoke): verify in real MioIsland app context that this probe returns 0 for a
        // job registered via `bootstrap user/$uid`. If it returns false-negative (job is loaded but
        // probe returns 1), consider switching to `launchctl print user/$(uid)/<label>` to match
        // the bootstrap domain, or checking the plist file existence as a fallback.
        // This only affects status display (Start/Stop control flow uses bootstrap-first/kickstart).
        let launchLoaded = binExists ? await shellCheck("/bin/launchctl", args: ["list", launchLabel]) : false

        // Process running via pgrep
        let procRunning = await shellCheck("/usr/bin/pgrep", args: ["-x", "mio-agent"])

        // Health endpoint (only meaningful when process is running)
        let healthy = procRunning ? await pingHealth() : false

        await MainActor.run {
            snap.binaryExists = binExists
            snap.launchAgentLoaded = binExists ? launchLoaded : false
            snap.processRunning = procRunning
            snap.healthReachable = healthy
            snap.socketExists = sockExists
            snap.logFileExists = logExists
            snap.lastCheckedAt = Date()

            // Phase determination (order matters)
            if !binExists {
                snap.phase = .notInstalled
            } else if !launchLoaded {
                snap.phase = .installedUnloaded
            } else if !procRunning {
                snap.phase = .loadedStopped
            } else if healthy {
                snap.phase = .runningHealthy
            } else {
                snap.phase = .runningUnhealthy
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

    private func shellCheck(_ cmd: String, args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
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
            snap.phase = .starting
            snap.lastDiagnostic = "Installing…"
        }

        guard let srcPath = Bundle.main.path(forResource: "mio-agent", ofType: nil) else {
            await MainActor.run {
                snap.phase = .error
                snap.lastDiagnostic = "mio-agent was not found in the app bundle."
            }
            return
        }

        let mioDir = (binaryPath as NSString).deletingLastPathComponent
        let launchAgentsDir = (plistPath as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: mioDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: binaryPath) {
                try FileManager.default.removeItem(atPath: binaryPath)
            }
            try FileManager.default.copyItem(atPath: srcPath, toPath: binaryPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath)

            // Ad-hoc codesign required on Apple Silicon for launchd/Keychain access
            await shellRun("/usr/bin/codesign", args: ["--sign", "-", "--force", binaryPath])

            let plistContent = launchAgentPlist()
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)

            // Bootstrap (register + start the job)
            let uid = "\(getuid())"
            let bootstrapExit = await shellRun("/bin/launchctl", args: ["bootstrap", "user/\(uid)", plistPath])
            if bootstrapExit != 0 {
                await MainActor.run {
                    snap.lastDiagnostic = "Could not register LaunchAgent. Check Logs for launchctl output."
                }
            } else {
                await MainActor.run { snap.lastDiagnostic = nil }
            }
        } catch {
            await MainActor.run {
                snap.phase = .error
                snap.lastDiagnostic = "Install failed: \(error.localizedDescription)"
            }
            await refreshStatus()
            return
        }

        await refreshStatus()
    }

    private func startAgent() async {
        await MainActor.run {
            snap.phase = .starting
            snap.lastDiagnostic = "Starting…"
        }
        let uid = "\(getuid())"
        // Bootstrap-first / kickstart-on-already-loaded pattern (idiomatic, no TOCTOU).
        // - Not loaded → bootstrap succeeds (exit 0), job registered and started.
        // - Already loaded → bootstrap returns non-zero ("service already loaded");
        //   fall back to `kickstart -k` which restarts the process.
        let bootstrapExit = await shellRun("/bin/launchctl", args: ["bootstrap", "user/\(uid)", plistPath])
        if bootstrapExit != 0 {
            let kickExit = await shellRun("/bin/launchctl", args: ["kickstart", "-k", "user/\(uid)/\(launchLabel)"])
            if kickExit != 0 {
                await MainActor.run {
                    snap.phase = .error
                    snap.lastDiagnostic = "Could not start the loaded job. Check Logs."
                }
                await refreshStatus()
                return
            }
        }
        await refreshStatus()
        await MainActor.run {
            if snap.phase != .runningHealthy && snap.phase != .runningUnhealthy {
                snap.lastDiagnostic = "Start command sent — verify status above."
            } else {
                snap.lastDiagnostic = nil
            }
        }
    }

    private func stopAgent() async {
        await MainActor.run {
            snap.phase = .stopping
            snap.lastDiagnostic = "Stopping…"
        }

        // TODO(Phase2): Replace with real IPC drain — send drain request via agent.sock,
        // wait for irreversible in-flight actions to reach transmission_complete or
        // needs_human (spec: 8s deadline), then proceed with bootout.
        // Phase 1: no IPC, proceed directly to bootout.
        await requestDrain(deadlineMs: 8_000)

        let uid = "\(getuid())"
        let bootoutExit = await shellRun("/bin/launchctl", args: ["bootout", "user/\(uid)/\(launchLabel)"])
        if bootoutExit != 0 {
            await MainActor.run {
                snap.phase = .error
                snap.lastDiagnostic = "Could not unload LaunchAgent. Refresh status or check Logs."
            }
            await refreshStatus()
            return
        }

        await refreshStatus()
        await MainActor.run {
            if snap.processRunning {
                snap.lastDiagnostic = "Process still running after stop request."
            } else {
                snap.lastDiagnostic = nil
            }
        }
    }

    /// IPC drain stub — no-op in Phase 1.
    ///
    /// Phase 2 implementation: open a Unix socket to socketPath (agent.sock),
    /// send a drain request, await acknowledgment or deadline.
    /// On deadline, proceed with bootout — ExitTimeOut=15s provides a final safety window.
    private func requestDrain(deadlineMs: Int) async {
        _ = deadlineMs  // intentional Phase 2 signature
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

    // MARK: - Log helpers

    private func openLogFile() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mio/agent.log")
        NSWorkspace.shared.open(logURL)
    }

    private func copyLastLinesOfLog(count: Int) {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let lastLines = Array(lines.suffix(count)).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastLines, forType: .string)
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
