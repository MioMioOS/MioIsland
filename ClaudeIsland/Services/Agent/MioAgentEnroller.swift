//
//  MioAgentEnroller.swift
//  ClaudeIsland
//
//  R2.1 — In-app machine enrollment by SHELLING OUT to the installed
//  `mio-agent` binary. We run `mio-agent login --server <url> --device-name
//  <name>` via Process and let the binary itself write the macOS Keychain
//  (machine_token) + ~/.mio/agent.json. We do NOT reimplement Keychain or the
//  enrollment protocol — that is the whole point of shelling out.
//
//  Coordination with the dual QR (R2.7):
//    `mio-agent login` creates its OWN enrollment intent server-side and prints
//    a `mio://enroll/<intent_id>?code=…&server=…` deeplink to stdout, then
//    long-polls GET /api/v1/enrollment-intents/:id until the phone approves.
//    We parse that deeplink off login's stdout to learn the SAME intent_id +
//    opaque_code the binary is polling, and surface them so the monitoring QR
//    can embed them (kind: "both"). The phone then approves THAT intent, login's
//    poll resolves, and login writes Keychain + agent.json. One scan, both jobs.
//
//  The autonomous_agent block of agent.json is plain JSON (no Keychain), so the
//  optional autonomous-agent editor merges it into the login-written agent.json
//  in place, preserving every field login wrote.
//

import Combine
import Foundation
import os.log

// MARK: - Enroll phase (UI-facing state machine)

/// Phases of the in-app enrollment shell-out. Drives the enroll card UI.
enum MioEnrollPhase: Equatable {
    /// No enrollment in progress.
    case idle
    /// `mio-agent login` launched; waiting for it to print the deeplink.
    case launching
    /// Deeplink parsed; QR is live; long-polling for phone approval.
    case awaitingApproval
    /// login exited 0 — Keychain + agent.json written by the binary.
    case succeeded
    /// login exited non-zero, timed out, or could not be launched.
    case failed(String)

    var isActive: Bool {
        switch self {
        case .launching, .awaitingApproval: return true
        default: return false
        }
    }
}

/// The enrollment intent parsed from `mio-agent login` stdout. These are the
/// values the binary is actively long-polling, so embedding them in the
/// monitoring QR guarantees the phone approves the intent login is watching.
struct MioEnrollIntent: Equatable {
    let intentId: String
    let opaqueCode: String
    /// Full `mio://enroll/...` deeplink, kept for the paste-into-Safari fallback.
    let deeplink: String
}

// MARK: - MioAgentEnroller

/// Owns the `mio-agent login` subprocess lifecycle and parses its output.
/// `@MainActor` so its `@Published` state drives SwiftUI directly.
@MainActor
final class MioAgentEnroller: ObservableObject {

    static let shared = MioAgentEnroller()
    static let logger = Logger(subsystem: "com.codeisland", category: "MioAgentEnroller")

    @Published private(set) var phase: MioEnrollPhase = .idle
    /// Parsed enrollment intent (intent_id + opaque_code) once login prints it.
    @Published private(set) var intent: MioEnrollIntent?
    /// Tail of login stdout/stderr (for the in-app diagnostic line). Capped.
    @Published private(set) var lastLine: String = ""

    /// The installed binary path — same location MioAgentDistribution installs to.
    let binaryPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/bin/mio-agent").path
    let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mio/agent.json").path

    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?

    private init() {}

    var binaryExists: Bool { FileManager.default.fileExists(atPath: binaryPath) }
    var configExists: Bool { FileManager.default.fileExists(atPath: configPath) }

    /// Enrollment is launchable when EITHER npx-cached OR an installed binary is
    /// present (task #117). npx makes the GitHub-binary download optional.
    var canEnroll: Bool {
        if case .success = MioAgentLauncher.resolve() { return true }
        return false
    }

    // MARK: - Enroll (shell out to `mio-agent login`)

    /// Launch `mio-agent login --server <url> --device-name <name>`.
    ///
    /// - The binary owns Keychain + agent.json. We only orchestrate + observe.
    /// - `onIntent` fires once the `mio://enroll/...` deeplink is parsed, so the
    ///   caller can refresh the dual QR to embed this exact intent.
    /// - Re-runnable: cancels any in-flight login first.
    func startEnrollment(serverUrl: String, deviceName: String, onIntent: @escaping (MioEnrollIntent) -> Void) {
        // Resolve npx-cached first, installed binary as fallback (#117). If neither
        // is available, fail with a clear message rather than silently no-op.
        let launch: MioAgentLauncher.Launch
        switch MioAgentLauncher.resolve() {
        case .success(let l): launch = l
        case .failure:
            phase = .failed(L10n.agentEnrollErrNoLauncher)
            return
        }
        // Tear down any previous attempt cleanly.
        cancelEnrollment()

        phase = .launching
        intent = nil
        lastLine = ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch.executablePath)
        proc.arguments = launch.prefixArgs + ["login", "--server", serverUrl, "--device-name", deviceName]
        proc.environment = MioAgentLauncher.childEnvironment(for: launch)
        Self.logger.info("Enroll via \(String(describing: launch.kind), privacy: .public) launcher: \(launch.executablePath, privacy: .public)")

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Stream stdout line by line. login prints the deeplink early, then
        // emits progress lines while polling; we parse the deeplink and keep a
        // tail of the most recent line for the UI.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.ingest(chunk, onIntent: onIntent) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self.ingest(chunk, onIntent: onIntent) }
        }

        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            guard let self else { return }
            Task { @MainActor in self.handleTermination(exitCode: code) }
        }

        do {
            try proc.run()
            self.process = proc
            self.outPipe = outPipe
            self.errPipe = errPipe
            Self.logger.info("mio-agent login launched (server=\(serverUrl, privacy: .public) name=\(deviceName, privacy: .public))")
        } catch {
            phase = .failed(L10n.agentEnrollErrLaunch(error.localizedDescription))
            Self.logger.error("Failed to launch mio-agent login: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - One QR = both (task #118)

    /// Proactively create a workspace enrollment intent so the Pair-iPhone QR
    /// carries BOTH monitoring AND workspace by default — one scan does everything.
    ///
    /// Called when a QR surface appears. It only starts a silent enrollment when:
    ///   - the daemon is launchable (npx-cached or installed binary), AND
    ///   - this Mac is NOT already enrolled (agent.json absent), AND
    ///   - no enrollment is already in flight (idle phase, no intent), AND
    ///   - a server URL is known.
    /// Otherwise it is a no-op and the QR degrades to monitor-only — never blocking
    /// the common monitoring-pair case behind workspace setup.
    ///
    /// `mio-agent login` long-polls the intent it prints; the phone approving the
    /// intent embedded in the QR resolves that same poll. If the QR window closes
    /// without a scan, the in-flight login is cancelled (see QR surface onDisappear).
    func ensureWorkspaceIntentForQR(serverUrl: String?) {
        guard let server = serverUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !server.isEmpty else { return }
        // NOTE: do NOT gate on `configExists`. A stale/archived enrollment (or simply wanting
        // to re-associate to another account/workspace) must still be re-pairable by scanning —
        // "already enrolled" is not a reason to refuse a fresh QR. Re-scanning re-associates.
        // Already have a fresh intent or an enrollment in flight → nothing to do (avoid spawning
        // a second login each time the QR surface re-appears in the same session).
        guard intent == nil, phase == .idle else { return }
        // Daemon not launchable → can't create an intent; QR stays monitor-only.
        guard canEnroll else { return }

        Self.logger.info("Auto-starting workspace enrollment for one-QR-both (#118)")
        startEnrollment(
            serverUrl: server,
            deviceName: Host.current().localizedName ?? "Mac"
        ) { _ in
            // Intent parsed — the QR surfaces observing `intent` re-render into
            // kind:"both" automatically.
        }
    }

    /// Cancel an in-flight enrollment. Terminates the polling subprocess so it
    /// stops holding the (now stale) intent open. Safe to call when idle.
    func cancelEnrollment() {
        if let p = process, p.isRunning {
            p.terminationHandler = nil
            p.terminate()
        }
        detachPipeHandlers()
        process = nil
        if phase.isActive { phase = .idle }
    }

    /// Null out the readability handlers and drop pipe references so they don't
    /// fire on EOF after the subprocess ends (a common Process/Pipe pitfall).
    private func detachPipeHandlers() {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        errPipe = nil
    }

    /// Reset back to idle after a terminal phase, so the card can be reused.
    func reset() {
        cancelEnrollment()
        phase = .idle
        intent = nil
        lastLine = ""
    }

    // MARK: - Output ingestion

    private func ingest(_ chunk: String, onIntent: @escaping (MioEnrollIntent) -> Void) {
        for rawLine in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            lastLine = String(line.prefix(240))

            // Parse the deeplink the first time we see it. login prints it both
            // standalone and inside the "(or paste this URL …)" hint line, so we
            // scan for the `mio://enroll/` substring anywhere on the line.
            if intent == nil, let parsed = Self.parseEnrollDeeplink(from: line) {
                intent = parsed
                if phase == .launching { phase = .awaitingApproval }
                Self.logger.info("Parsed enroll intent \(parsed.intentId.prefix(8), privacy: .public) from login output")
                onIntent(parsed)
            }
        }
    }

    private func handleTermination(exitCode: Int32) {
        // Deterministically DRAIN any bytes the edge-triggered readability handlers didn't
        // consume — especially the final error line on a fast-failing login. The per-chunk
        // ingest Tasks and this termination Task both hop onto the main actor with NO ordering
        // guarantee, so racing them intermittently lost mio-agent's real reason and showed a
        // generic "exited N" instead. We detach the handlers, then synchronously read what's
        // left and fold it into lastLine BEFORE building the error detail.
        let outHandle = outPipe?.fileHandleForReading
        let errHandle = errPipe?.fileHandleForReading
        outHandle?.readabilityHandler = nil
        errHandle?.readabilityHandler = nil
        for handle in [outHandle, errHandle].compactMap({ $0 }) {
            let rest = handle.readDataToEndOfFile()
            if let tail = String(data: rest, encoding: .utf8), !tail.isEmpty {
                for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { lastLine = String(line.prefix(240)) }
                }
            }
        }
        outPipe = nil
        errPipe = nil
        process = nil
        if exitCode == 0 {
            phase = .succeeded
            Self.logger.info("mio-agent login succeeded — Keychain + agent.json written by the binary")
        } else {
            // Prefer the captured tail (login prints a human-readable error on
            // its last line for timeouts / 403 / network errors).
            let detail = lastLine.isEmpty ? L10n.agentEnrollErrExit(exitCode) : lastLine
            phase = .failed(detail)
            Self.logger.error("mio-agent login exited \(exitCode): \(detail, privacy: .public)")
        }
    }

    // MARK: - Deeplink parsing

    /// Extract intent_id + opaque_code from a `mio://enroll/<id>?code=…&server=…`
    /// deeplink embedded anywhere in `line`. Returns nil if no valid deeplink.
    static func parseEnrollDeeplink(from line: String) -> MioEnrollIntent? {
        guard let range = line.range(of: "mio://enroll/") else { return nil }
        // The deeplink runs from the scheme to the first whitespace or closing
        // paren (login wraps it in "(... )"). Slice from the marker to that edge.
        var tail = String(line[range.lowerBound...])
        if let stop = tail.firstIndex(where: { $0 == " " || $0 == ")" || $0 == "\t" }) {
            tail = String(tail[tail.startIndex..<stop])
        }
        let deeplink = tail

        // mio://enroll/<intentId>?code=<code>&server=…
        guard let afterScheme = deeplink.range(of: "mio://enroll/") else { return nil }
        let rest = String(deeplink[afterScheme.upperBound...])
        guard let qMark = rest.firstIndex(of: "?") else { return nil }
        let intentId = String(rest[rest.startIndex..<qMark])
        guard !intentId.isEmpty else { return nil }

        let queryString = String(rest[rest.index(after: qMark)...])
        var code: String?
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "code" {
                code = kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        guard let opaqueCode = code, !opaqueCode.isEmpty else { return nil }

        return MioEnrollIntent(intentId: intentId, opaqueCode: opaqueCode, deeplink: deeplink)
    }

    // MARK: - Autonomous agent block (plain JSON merge into agent.json)

    /// The optional autonomous_agent loop config, mirrors AutonomousAgentConfig
    /// in mio-agent src/config/types.ts. Default-off semantics: `enabled:false`
    /// or an absent block means the loop does not start.
    struct AutonomousAgentBlock: Codable, Equatable {
        var enabled: Bool
        var workroom_id: String
        var channel_id: String
        var handle: String
        var quiet_seconds: Int
        var max_replies_per_window: Int
        var window_seconds: Int

        static let defaults = AutonomousAgentBlock(
            enabled: false,
            workroom_id: "",
            channel_id: "",
            handle: "@agent",
            quiet_seconds: 30,
            max_replies_per_window: 8,
            window_seconds: 600
        )
    }

    enum ConfigError: LocalizedError {
        case notConfigured
        case malformed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return L10n.agentEnrollErrConfigMissing
            case .malformed(let m): return L10n.agentEnrollErrConfigMalformed(m)
            case .writeFailed(let m): return L10n.agentEnrollErrConfigWrite(m)
            }
        }
    }

    /// Read the current autonomous_agent block from agent.json, if present.
    /// Returns nil when agent.json exists but carries no autonomous_agent block.
    func readAutonomousBlock() throws -> AutonomousAgentBlock? {
        guard configExists else { throw ConfigError.notConfigured }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: configPath)) }
        catch { throw ConfigError.malformed(error.localizedDescription) }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ConfigError.malformed("agent.json is not a JSON object")
        }
        guard let block = root["autonomous_agent"] as? [String: Any] else { return nil }
        let blockData = try JSONSerialization.data(withJSONObject: block)
        return try? JSONDecoder().decode(AutonomousAgentBlock.self, from: blockData)
    }

    /// Merge `block` into agent.json's `autonomous_agent` key WITHOUT disturbing
    /// any other field login wrote (machine_id, org_id, keychain_item_ref, …).
    /// Re-reads the file, mutates one key, re-serializes, writes 0600.
    func writeAutonomousBlock(_ block: AutonomousAgentBlock) throws {
        guard configExists else { throw ConfigError.notConfigured }
        let url = URL(fileURLWithPath: configPath)
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ConfigError.malformed(error.localizedDescription) }

        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ConfigError.malformed("agent.json is not a JSON object")
        }

        let blockData = try JSONEncoder().encode(block)
        guard let blockDict = (try? JSONSerialization.jsonObject(with: blockData)) as? [String: Any] else {
            throw ConfigError.malformed("could not serialize autonomous_agent block")
        }
        root["autonomous_agent"] = blockDict

        do {
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
            // Preserve the 0600 mode login set (atomic write can reset perms).
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        } catch {
            throw ConfigError.writeFailed(error.localizedDescription)
        }
        Self.logger.info("Merged autonomous_agent block into agent.json (enabled=\(block.enabled, privacy: .public))")
    }

    /// Remove the autonomous_agent block entirely (returns the daemon to
    /// default-off without leaving an `enabled:false` stub).
    func clearAutonomousBlock() throws {
        guard configExists else { throw ConfigError.notConfigured }
        let url = URL(fileURLWithPath: configPath)
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ConfigError.malformed("agent.json is not a JSON object")
        }
        root.removeValue(forKey: "autonomous_agent")
        do {
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        } catch {
            throw ConfigError.writeFailed(error.localizedDescription)
        }
    }
}
