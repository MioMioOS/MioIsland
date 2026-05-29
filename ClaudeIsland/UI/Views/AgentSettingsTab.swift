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
        case .checking:          return L10n.agentPhaseLabelChecking
        case .notInstalled:      return L10n.agentPhaseLabelNotInstalled
        case .notConfigured:     return L10n.agentPhaseLabelNotConfigured
        case .installedUnloaded: return L10n.agentPhaseLabelInstalledUnloaded
        case .loadedStopped:     return L10n.agentPhaseLabelLoadedStopped
        case .starting:          return L10n.agentPhaseLabelStarting
        case .runningHealthy:    return L10n.agentPhaseLabelRunningHealthy
        case .runningUnhealthy:  return L10n.agentPhaseLabelRunningUnhealthy
        case .draining:          return L10n.agentPhaseLabelDraining
        case .stopping:          return L10n.agentPhaseLabelStopping
        case .error:             return L10n.agentPhaseLabelError
        case .unknown:           return L10n.agentPhaseLabelUnknown
        }
    }

    var descriptionText: String {
        switch self {
        case .checking:          return L10n.agentPhaseDescChecking
        case .notInstalled:      return L10n.agentPhaseDescNotInstalled
        case .notConfigured:     return L10n.agentPhaseDescNotConfigured
        case .installedUnloaded: return L10n.agentPhaseDescInstalledUnloaded
        case .loadedStopped:     return L10n.agentPhaseDescLoadedStopped
        case .starting:          return L10n.agentPhaseDescStarting
        case .runningHealthy:    return L10n.agentPhaseDescRunningHealthy
        case .runningUnhealthy:  return L10n.agentPhaseDescRunningUnhealthy
        case .draining:          return L10n.agentPhaseDescDraining
        case .stopping:          return L10n.agentPhaseDescStopping
        case .error:             return ""   // diagnostic carried in snap.lastDiagnostic
        case .unknown:           return L10n.agentPhaseDescUnknown
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
        return L10n.agentLastChecked(fmt.string(from: date))
    }
}

// MARK: - AgentSettingsTab

struct AgentSettingsTab: View {
    @State private var snap = AgentLifecycleSnapshot()
    @ObservedObject private var enroller = MioAgentEnroller.shared

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
    private let healthURL = URL(string: "http://127.0.0.1:7878/health")!
    private let launchLabel = "io.miomioos.mio-agent"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Description
            Text(L10n.agentTabDescription)
                .font(.system(size: 11))
                .foregroundColor(Theme.subtle)

            // MARK: Overall status card
            overallStatusCard

            // MARK: Lifecycle detail rows
            SectionLabel(L10n.agentSectionLifecycle)
            lifecycleDetailRows

            // MARK: Workspace enrollment (R2.1 — shells out to `mio-agent login`)
            // Shown whenever the binary is installed. The card adapts: enroll
            // form when unconfigured, status while enrolling, "already enrolled"
            // once agent.json exists.
            if snap.binaryExists {
                SectionLabel(L10n.agentEnrollSection)
                EnrollWorkspaceCard(
                    serverUrl: SyncManager.shared.serverUrl,
                    isConfigured: snap.configExists,
                    onChanged: { Task { await refreshStatus() } }
                )
            }

            // MARK: Autonomous agent block (plain JSON merge into agent.json)
            if snap.configExists {
                SectionLabel(L10n.agentAutoSection)
                AutonomousAgentCard()
            }

            // MARK: Controls
            SectionLabel(L10n.agentSectionControls)
            controlsCard

            // MARK: Logs card
            SectionLabel(L10n.agentSectionLogs)
            logsCard

            // MARK: Upcoming capabilities
            SectionLabel(L10n.agentSectionCapabilities)
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
                        ? (snap.lastDiagnostic ?? L10n.agentDiagErrorFallback)
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
                title: L10n.agentRowBinary,
                path: binaryPath,
                state: snap.binaryExists
                    ? (L10n.agentStateInstalled, Theme.success)
                    : (L10n.agentStateMissing, Theme.error)
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "gearshape.fill",
                title: L10n.agentRowConfig,
                path: configPath,
                state: snap.configExists
                    ? (L10n.agentStateConfigPresent, Theme.success)
                    : (L10n.agentStateConfigMissing, Theme.warning)
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "gear",
                title: L10n.agentRowLaunchAgent,
                path: launchLabel,
                state: {
                    switch snap.launchAgentLoaded {
                    case .some(true):  return (L10n.agentStateLoaded, Theme.success)
                    case .some(false): return (L10n.agentStateUnloaded, Theme.warning)
                    case .none:        return (L10n.agentStateUnknown, Theme.neutralDot)
                    }
                }()
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "bolt.fill",
                title: L10n.agentRowProcess,
                path: "mio-agent",
                state: snap.processRunning
                    ? (L10n.agentStateRunning, Theme.success)
                    : (L10n.agentStateStopped, Theme.warning)
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "heart.fill",
                title: L10n.agentRowHealth,
                path: "127.0.0.1:7878",
                state: snap.healthReachable
                    ? (L10n.agentStateOK, Theme.success)
                    : (snap.processRunning ? L10n.agentStateFailed : L10n.agentStateUnavailable,
                       snap.processRunning ? Theme.error : Theme.neutralDot)
            )
            Divider().opacity(0.3)
            lifecycleRow(
                icon: "point.3.connected.trianglepath.dotted",
                title: L10n.agentRowSocket,
                path: "~/.mio/agent.sock",
                state: (L10n.agentStateSocketPending, Theme.neutralDot),
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
                        label: L10n.agentButtonInstall,
                        icon: "arrow.down.circle.fill",
                        enabled: !snap.isBusy
                    ) { await installAgent() }
                }

                // Start: shown when installed + configured + not running
                if snap.binaryExists && snap.configExists && !snap.processRunning
                    && snap.phase != .starting && snap.phase != .stopping {
                    accentButton(
                        label: L10n.agentButtonStart,
                        icon: "play.fill",
                        enabled: !snap.isBusy
                    ) { await startAgent() }
                }

                // Stop: shown when running or job loaded
                if snap.processRunning || snap.launchAgentLoaded == true {
                    if snap.phase != .starting && snap.phase != .stopping {
                        outlineButton(
                            label: L10n.agentButtonStop,
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

            // Setup required hint: when agent.json is missing, point the user at
            // the in-app Workspace enrollment card above. The old "run mio-agent
            // login in Terminal" stub is retired (#R2.1) — enrollment is in-app.
            if snap.phase == .notConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.subtle)
                    Text(L10n.agentPhaseDescNotConfigured)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.subtle)
                        .fixedSize(horizontal: false, vertical: true)
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
                Text(L10n.agentLogsHint)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.subtle)

                HStack(spacing: 8) {
                    accentButton(label: L10n.agentButtonOpenLog, icon: "doc.text", enabled: true) {
                        openLogFile()
                    }
                    outlineButton(label: L10n.agentButtonCopyLog, icon: "doc.on.clipboard", enabled: true) {
                        copyLastLinesOfLog(count: 100)
                    }
                }

                if !snap.logFileExists {
                    Text(L10n.agentLogsEmpty)
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
                label: L10n.agentCapActionExecution,
                sublabel: L10n.agentCapActionDesc
            )
            unavailableRow(
                icon: "rectangle.3.group.fill",
                label: L10n.agentCapWorkroom,
                sublabel: L10n.agentCapWorkroomDesc
            )
            unavailableRow(
                icon: "list.bullet.rectangle.fill",
                label: L10n.agentCapLogStreaming,
                sublabel: L10n.agentCapLogStreamingDesc
            )
            unavailableRow(
                icon: "arrow.up.circle.fill",
                label: L10n.agentCapAutoUpgrade,
                sublabel: L10n.agentCapAutoUpgradeDesc,
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
            Text(L10n.agentCapSoon)
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
        let healthResult = procRunning ? await pingHealth() : (reachable: false, error: nil as String?)
        let healthy = healthResult.reachable

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
                // Surface the actual probe failure so the user can see why health is red.
                if let healthError = healthResult.error {
                    snap.lastDiagnostic = healthError
                }
            }
        }
    }

    /// Probe the daemon health endpoint. Returns reachable=true on HTTP 200.
    /// On any failure (non-200 or network error) returns reachable=false with a human-readable
    /// error string so the UI can surface the real reason instead of a generic "unhealthy" label.
    private func pingHealth() async -> (reachable: Bool, error: String?) {
        do {
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 2.0
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return (true, nil)
            } else {
                return (false, "Health probe HTTP \(status) — expected 200")
            }
        } catch {
            return (false, "Health probe: \(error.localizedDescription)")
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
            snap.lastDiagnostic = L10n.agentDiagInstalling
        }

        let mioDir = (binaryPath as NSString).deletingLastPathComponent
        let launchAgentsDir = (plistPath as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: mioDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

            // Download, verify (SHA-256), extract, and atomically install the daemon binary
            // from the GitHub Release artifact. This replaces the old bundle-lookup approach
            // (Bundle.main.path forResource:"mio-agent") — the Resources phase is intentionally
            // empty; the binary is always fetched fresh from the pinned release tag (#121).
            //
            // No-overwrite-on-fail: MioAgentDistribution only writes to binaryPath after all
            // verification passes; any earlier failure leaves the existing binary intact.
            try await MioAgentDistribution.downloadAndInstall(
                to: binaryPath,
                onProgress: { [self] msg in
                    Task { @MainActor in snap.lastDiagnostic = msg }
                }
            )

            // Ad-hoc codesign required on Apple Silicon for launchd/Keychain access
            await MainActor.run { snap.lastDiagnostic = "Signing binary..." }
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
                        ? L10n.agentDiagBootstrapFailed(bootstrapExit)
                        : bootstrapErr
                }
            } else {
                await MainActor.run { snap.lastDiagnostic = nil }
            }
        } catch {
            await MainActor.run {
                snap.phase = .error
                snap.lastDiagnostic = L10n.agentDiagInstallFailed(error.localizedDescription)
            }
            await refreshStatus()
            return
        }

        await refreshStatus()
    }

    private func startAgent() async {
        await MainActor.run {
            snap.phase = .starting
            snap.lastDiagnostic = L10n.agentDiagStarting
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
                    diagMsg = L10n.agentDiagStartFailed(bootstrapExit: bootstrapExit, kickExit: kickExit)
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
                snap.lastDiagnostic = L10n.agentDiagStartSent
            } else {
                snap.lastDiagnostic = nil
            }
        }
    }

    private func stopAgent() async {
        await MainActor.run {
            snap.phase = .stopping
            snap.lastDiagnostic = L10n.agentDiagStopping
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
                    ? L10n.agentDiagStopFailed(bootoutExit)
                    : bootoutErr
            }
            await refreshStatus()
            return
        }

        await refreshStatus()
        await MainActor.run {
            if snap.processRunning {
                snap.lastDiagnostic = L10n.agentDiagProcessStillRunning
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
            let diag = snap.lastDiagnostic ?? L10n.agentDiagNoLog
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

// MARK: - EnrollWorkspaceCard (R2.1 in-app enrollment)

/// In-app workspace enrollment. Shells out to `mio-agent login` (which owns the
/// Keychain + agent.json write) and surfaces the enroll intent it is polling so
/// the Pair-iPhone QR can carry it (R2.7 dual QR). Replaces the retired
/// "run mio-agent login in Terminal" stub.
private struct EnrollWorkspaceCard: View {
    /// The currently configured CodeLight/MioServer URL (from SyncManager).
    let serverUrl: String?
    /// True when ~/.mio/agent.json already exists (already enrolled).
    let isConfigured: Bool
    /// Called after a successful enroll or cancel so the parent re-probes status.
    let onChanged: () -> Void

    @ObservedObject private var enroller = MioAgentEnroller.shared
    @State private var serverDraft: String = ""
    @State private var deviceDraft: String = Host.current().localizedName ?? "Mac"

    private var effectiveServer: String {
        let s = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? (serverUrl ?? "") : s
    }

    private var isValidServer: Bool {
        guard let u = URL(string: effectiveServer), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && (u.host?.isEmpty == false)
    }

    var body: some View {
        SettingsCard {
            switch enroller.phase {
            case .idle:
                if isConfigured { alreadyConfiguredContent } else { enrollFormContent }
            case .launching, .awaitingApproval:
                inProgressContent
            case .succeeded:
                succeededContent
            case .failed(let msg):
                failedContent(msg)
            }
        }
        .onAppear {
            // Seed the server field from the configured URL so the user usually
            // just clicks Enroll. Editable in case they want a different server.
            if serverDraft.isEmpty { serverDraft = serverUrl ?? "" }
        }
    }

    // MARK: States

    private var enrollFormContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.agentEnrollNeededTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.detailText)
            Text(L10n.agentEnrollNeededBody)
                .font(.system(size: 11))
                .foregroundColor(Theme.subtle)
                .fixedSize(horizontal: false, vertical: true)

            labeledField(label: L10n.agentEnrollServerLabel,
                         placeholder: L10n.agentEnrollServerPlaceholder,
                         text: $serverDraft)
            labeledField(label: L10n.agentEnrollDeviceLabel,
                         placeholder: "Mac",
                         text: $deviceDraft)

            actionButton(
                label: L10n.agentEnrollButtonStart,
                icon: "person.badge.key.fill",
                enabled: isValidServer
            ) {
                startEnroll()
            }
        }
    }

    private var inProgressContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text(enroller.phase == .launching
                     ? L10n.agentEnrollLaunching
                     : L10n.agentEnrollAwaiting)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.detailText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let intent = enroller.intent {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accent)
                    Text("intent \(intent.intentId.prefix(8))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.subtle)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(intent.deeplink, forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard").font(.system(size: 10))
                            Text(L10n.agentEnrollCopyDeeplink).font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Theme.subtleStrong)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !enroller.lastLine.isEmpty {
                Text(enroller.lastLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.subtle.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            outlineActionButton(label: L10n.agentEnrollButtonCancel, icon: "xmark") {
                enroller.cancelEnrollment()
                onChanged()
            }
        }
    }

    private var succeededContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.success)
                Text(L10n.agentEnrollSucceeded)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.detailText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionButton(label: L10n.agentEnrollButtonDone, icon: "checkmark", enabled: true) {
                enroller.reset()
                onChanged()
            }
        }
    }

    private func failedContent(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.error)
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionButton(label: L10n.agentEnrollButtonRetry, icon: "arrow.clockwise", enabled: isValidServer) {
                startEnroll()
            }
        }
    }

    private var alreadyConfiguredContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.success)
                Text(L10n.agentEnrollAlreadyConfigured)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            outlineActionButton(label: L10n.agentEnrollButtonReEnroll, icon: "arrow.triangle.2.circlepath") {
                startEnroll()
            }
        }
    }

    // MARK: Actions

    private func startEnroll() {
        guard isValidServer else { return }
        let server = effectiveServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = deviceDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        enroller.startEnrollment(
            serverUrl: server,
            deviceName: name.isEmpty ? (Host.current().localizedName ?? "Mac") : name
        ) { _ in
            // Intent parsed — the Pair-iPhone QR (observing enroller.intent)
            // re-renders into a dual kind:"both" QR automatically.
        }
    }

    // MARK: Field + button helpers (match tab styling)

    private func labeledField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.subtle)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.detailText.opacity(0.95))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldBorder, lineWidth: 0.5))
        }
    }

    private func actionButton(label: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(enabled ? Theme.backgroundInk : Theme.subtle)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(enabled ? Theme.accent : Theme.controlFill))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func outlineActionButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(Theme.detailText.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.controlFill)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AutonomousAgentCard (autonomous_agent block editor)

/// Edits the optional `autonomous_agent` block in ~/.mio/agent.json. This is
/// plain JSON (no Keychain), so we read/merge/write it in place WITHOUT
/// disturbing any field `mio-agent login` wrote.
private struct AutonomousAgentCard: View {
    @ObservedObject private var enroller = MioAgentEnroller.shared

    @State private var block = MioAgentEnroller.AutonomousAgentBlock.defaults
    @State private var loaded = false
    @State private var saveMessage: String? = nil
    @State private var saveIsError = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                // Enable toggle row
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.agentAutoEnabledLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.detailText.opacity(0.92))
                        Text(L10n.agentAutoEnabledSublabel)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $block.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                }

                if block.enabled {
                    field(L10n.agentAutoWorkroomLabel, text: $block.workroom_id, mono: true)
                    field(L10n.agentAutoChannelLabel, text: $block.channel_id, mono: true)
                    field(L10n.agentAutoHandleLabel, text: $block.handle, mono: false)
                    HStack(spacing: 8) {
                        intField(L10n.agentAutoQuietLabel, value: $block.quiet_seconds)
                        intField(L10n.agentAutoMaxRepliesLabel, value: $block.max_replies_per_window)
                        intField(L10n.agentAutoWindowLabel, value: $block.window_seconds)
                    }

                    if !requiredFilled {
                        Text(L10n.agentAutoRequiresWorkroom)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.warning)
                    }
                }

                HStack(spacing: 8) {
                    Button { save() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 10))
                            Text(L10n.agentAutoSave).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(saveEnabled ? Theme.backgroundInk : Theme.subtle)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(saveEnabled ? Theme.accent : Theme.controlFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(!saveEnabled)

                    Button { clear() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(.system(size: 10))
                            Text(L10n.agentAutoClear).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(Theme.detailText.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Theme.controlFill)
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                if let msg = saveMessage {
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundColor(saveIsError ? Theme.error : Theme.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private var requiredFilled: Bool {
        !block.workroom_id.trimmingCharacters(in: .whitespaces).isEmpty &&
        !block.channel_id.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Save is allowed when disabling (any state) or when enabling with the
    /// required identifiers filled in.
    private var saveEnabled: Bool { !block.enabled || requiredFilled }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let existing = (try? enroller.readAutonomousBlock()) ?? nil {
            block = existing
        }
    }

    private func save() {
        do {
            try enroller.writeAutonomousBlock(block)
            saveIsError = false
            saveMessage = L10n.agentAutoSaved
        } catch {
            saveIsError = true
            saveMessage = error.localizedDescription
        }
    }

    private func clear() {
        do {
            try enroller.clearAutonomousBlock()
            block = MioAgentEnroller.AutonomousAgentBlock.defaults
            saveIsError = false
            saveMessage = L10n.agentAutoSaved
        } catch {
            saveIsError = true
            saveMessage = error.localizedDescription
        }
    }

    private func field(_ label: String, text: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.subtle)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundColor(Theme.detailText.opacity(0.95))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldBorder, lineWidth: 0.5))
        }
    }

    private func intField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.subtle).lineLimit(1)
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.detailText.opacity(0.95))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.fieldBorder, lineWidth: 0.5))
        }
    }
}
