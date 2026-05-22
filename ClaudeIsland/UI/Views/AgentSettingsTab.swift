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
    case notConfigured      // binary present but ~/.mio/agent.json missing — needs `mio-agent login`
    case installedUnloaded  // binary + config present, launchd job not loaded
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
        case .notConfigured:                     return Theme.warning
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
        case .notConfigured:     return "Setup required"
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
        case .notConfigured:
            return "Agent is installed but not configured. Run mio-agent login in Terminal to set up before starting."
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
    var configExists: Bool = false      // ~/.mio/agent.json — required before Start
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
    private let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/agent.json").path
    private let plistPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/io.miomioos.mio-agent.plist").path
    private let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/agent.sock").path
    private let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/agent.log").path
    private let mioDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio")
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

                // Start: shown when installed + configured + not running
                if snap.binaryExists && snap.configExists && !snap.processRunning
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

            // Setup required hint: shown when agent.json is missing
            if snap.phase == .notConfigured {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Run this command in Terminal to configure the agent:")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.subtle)
                    HStack(spacing: 6) {
                        Text("mio-agent login")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.detailText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.controlFill)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("mio-agent login", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 10))
                                .foregroundColor(Theme.subtle)
                        }
                        .buttonStyle(.plain)
                        .help("Copy command")
                    }
                }
                .padding(.top, 4)
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
                    accentButton(label: "Open log file", icon: "doc.text", enabled: true) {
                        openLogFile()
                    }
                    outlineButton(label: "Copy last 100 lines", icon: "doc.on.clipboard", enabled: true) {
                        copyLastLinesOfLog(count: 100)
                    }
                }

                if !snap.logFileExists {
                    Text("No agent log yet — ~/.mio/agent.log will be created once the agent starts successfully.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.subtle.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
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
        let cfgExists = fm.fileExists(atPath: configPath)
        let sockExists = fm.fileExists(atPath: socketPath)
        let logExists = fm.fileExists(atPath: logPath)

        // LaunchAgent loaded: `launchctl list <label>` exits 0 if the service is visible in the
        // current launchctl session domain. From a GUI app process, this queries the gui/$uid domain,
        // which is correct since we bootstrap/kickstart/bootout into gui/$uid.
        let launchLoaded = binExists ? await shellCheck("/bin/launchctl", args: ["list", launchLabel]) : false

        // Process running via pgrep
        let procRunning = await shellCheck("/usr/bin/pgrep", args: ["-x", "mio-agent"])

        // Health endpoint (only meaningful when process is running)
        let healthy = procRunning ? await pingHealth() : false

        await MainActor.run {
            snap.binaryExists = binExists
            snap.configExists = cfgExists
            snap.launchAgentLoaded = binExists ? launchLoaded : false
            snap.processRunning = procRunning
            snap.healthReachable = healthy
            snap.socketExists = sockExists
            snap.logFileExists = logExists
            snap.lastCheckedAt = Date()

            // Phase determination (order matters)
            if !binExists {
                snap.phase = .notInstalled
            } else if !cfgExists {
                // Binary installed but agent.json missing: user must run `mio-agent login` first.
                // Starting without config causes the agent to Fatal immediately and launchd
                // restart-loops (KeepAlive=true) — block Start until config is present.
                snap.phase = .notConfigured
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

            // Bootstrap into gui/$uid — the correct launchd domain for LaunchAgents loaded
            // from ~/Library/LaunchAgents/ in a GUI session (distinct from user/$uid).
            let uid = "\(getuid())"
            let (bootstrapExit, bootstrapErr) = await shellRun("/bin/launchctl", args: ["bootstrap", "gui/\(uid)", plistPath])
            if bootstrapExit != 0 {
                await MainActor.run {
                    snap.lastDiagnostic = bootstrapErr.isEmpty
                        ? "Could not register LaunchAgent (launchctl exit \(bootstrapExit))."
                        : bootstrapErr
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
        // Bootstrap-first / kickstart-on-already-loaded pattern into gui/$uid
        // (correct domain for LaunchAgents in ~/Library/LaunchAgents/ from a GUI session).
        // - Not loaded → bootstrap succeeds (exit 0), job registered and started.
        // - Already loaded → bootstrap returns non-zero ("Bootstrap failed: 5");
        //   fall back to `kickstart -k` which restarts the process.
        let (bootstrapExit, bootstrapErr) = await shellRun("/bin/launchctl", args: ["bootstrap", "gui/\(uid)", plistPath])
        if bootstrapExit != 0 {
            let (kickExit, kickErr) = await shellRun("/bin/launchctl", args: ["kickstart", "-k", "gui/\(uid)/\(launchLabel)"])
            if kickExit != 0 {
                let diagMsg: String
                if !kickErr.isEmpty {
                    diagMsg = kickErr
                } else if !bootstrapErr.isEmpty {
                    diagMsg = bootstrapErr
                } else {
                    diagMsg = "Start failed (bootstrap exit \(bootstrapExit), kickstart exit \(kickExit))."
                }
                await MainActor.run {
                    snap.phase = .error
                    snap.lastDiagnostic = diagMsg
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
        let (bootoutExit, bootoutErr) = await shellRun("/bin/launchctl", args: ["bootout", "gui/\(uid)/\(launchLabel)"])
        if bootoutExit != 0 {
            await MainActor.run {
                snap.phase = .error
                snap.lastDiagnostic = bootoutErr.isEmpty
                    ? "Could not unload LaunchAgent (launchctl exit \(bootoutExit))."
                    : bootoutErr
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

    /// Returns (exitCode, stderrOutput). Stderr is captured so callers can surface real launchctl errors.
    @discardableResult
    private func shellRun(_ cmd: String, args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmd)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            process.standardError = errPipe
            do {
                try process.run()
                process.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (process.terminationStatus, errStr))
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }

    // MARK: - Log helpers

    private func openLogFile() {
        if snap.logFileExists {
            let logURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".mio/agent.log")
            NSWorkspace.shared.open(logURL)
        } else {
            // No log yet — open ~/.mio/ directory so user can inspect the folder
            NSWorkspace.shared.open(mioDir)
        }
    }

    private func copyLastLinesOfLog(count: Int) {
        if snap.logFileExists,
           let content = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            let lastLines = Array(lines.suffix(count)).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lastLines, forType: .string)
        } else {
            // No log file: copy last diagnostic so user can share it
            let diag = snap.lastDiagnostic ?? "No agent log. The agent has not started successfully yet."
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(diag, forType: .string)
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
