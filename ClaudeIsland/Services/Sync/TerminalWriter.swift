//
//  TerminalWriter.swift
//  ClaudeIsland
//
//  Sends text to a Claude Code terminal session.
//  Used by the sync module to relay messages from the phone.
//

import Foundation
import AppKit
import ApplicationServices
import Darwin
import os.log

/// File-scope helper: spawn a subprocess on a background queue, read its stdout,
/// and force-kill it if it exceeds the given timeout. Returns `(stdout, success)`.
///
/// This exists because `Process().waitUntilExit()` + `readDataToEndOfFile()` are
/// synchronous and will freeze the main thread if the child hangs (cmux CLI
/// unresponsive, osascript denied by macOS TCC, etc.). Every subprocess launch
/// in TerminalWriter MUST go through this helper — do not add new raw
/// `try process.run()` sites.
///
/// `terminationGrace` is the SIGTERM→SIGKILL gap; we escalate if the child
/// doesn't exit on its own after SIGTERM.
private func runShellWithTimeout(
    _ executable: String,
    _ arguments: [String],
    timeout: TimeInterval = 5.0,
    terminationGrace: TimeInterval = 0.25
) async -> (output: String?, success: Bool) {
    await withCheckedContinuation { (continuation: CheckedContinuation<(String?, Bool), Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice

            do {
                try p.run()
            } catch {
                DebugLogger.log("Shell", "launch failed: \(executable) \(arguments.joined(separator: " ")) — \(error.localizedDescription)")
                continuation.resume(returning: (nil, false))
                return
            }

            // Watchdog: SIGTERM at `timeout`, SIGKILL at `timeout + grace` if still alive.
            let watchdog = DispatchWorkItem { [p] in
                guard p.isRunning else { return }
                DebugLogger.log("Shell", "timeout \(timeout)s — SIGTERM \(executable) \(arguments.first ?? "")")
                p.terminate()
                Thread.sleep(forTimeInterval: terminationGrace)
                if p.isRunning {
                    DebugLogger.log("Shell", "still alive after SIGTERM — SIGKILL \(executable)")
                    kill(p.processIdentifier, SIGKILL)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

            // Reads block until the pipe is closed — happens when the child exits
            // (normally or via watchdog termination above).
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()

            let output = String(data: data, encoding: .utf8)
            let success = p.terminationStatus == 0
            continuation.resume(returning: (output, success))
        }
    }
}

/// Sends text input to a Claude Code terminal session.
@MainActor
final class TerminalWriter {

    nonisolated static let logger = Logger(subsystem: "com.codeisland", category: "TerminalWriter")
    static let shared = TerminalWriter()

    private init() {}

    enum CmuxSubmissionPlan: Equatable {
        case appendReturn(String)
        case sendThenKey(text: String, key: String)
    }

    /// Decide the terminal backend once we know whether this session can be
    /// targeted precisely via cmux. cmux must win over the coarse
    /// `terminalApp` hint, otherwise Codex sessions labeled "Codex" bypass the
    /// cmux path even when the hook script already gave us exact cmux IDs.
    nonisolated static func preferredTerminalBackend(terminalApp: String?, hasCmuxTarget: Bool, detectedFallback: String?) -> String? {
        if hasCmuxTarget {
            return "cmux"
        }
        if let app = terminalApp, !app.isEmpty {
            return app.lowercased()
        }
        return detectedFallback
    }

    /// Every agent TUI we drive through cmux — Claude Code, Codex, Gemini,
    /// opencode — runs in raw mode with bracketed paste, so an inline `\r` is
    /// not a reliable way to submit:
    ///
    /// - Short payloads happen to submit, because cmux writes them as raw
    ///   keystrokes and `\r` *is* the Enter key.
    /// - Past a payload-size threshold (measured at ~128 bytes against
    ///   cmux 0.64.17) cmux switches to a bulk-text path, where the trailing
    ///   `\r` is inserted as a literal newline and the message is **stranded in
    ///   the composer, unsent** — while the phone still reports "delivered".
    /// - Worse, mapping every `\n` to `\r` means each newline is an Enter, so a
    ///   single multi-line message is **split into several submitted messages**.
    ///
    /// A real Enter *key* event has none of these problems and is correct for
    /// every payload size and shape, so it is now the only path. This function
    /// only ever feeds the cmux backend, and `cmux send-key` targets the
    /// workspace's active surface when `--surface` is omitted — the same
    /// surface `cmux send` just wrote to — so it is safe with or without an
    /// explicit surface. `terminalApp` / `hasSurfaceTarget` are kept for
    /// callers and diagnostics but no longer change the submit path.
    ///
    /// Previously only `terminalApp == "codex"` took this path. That check
    /// could never fire for a Claude Code session running inside cmux, whose
    /// `terminalApp` is `cmux` — `terminalApp` names the *terminal*, not the
    /// agent — so Claude kept the broken inline-`\r` path.
    nonisolated static func cmuxSubmissionPlan(text: String, terminalApp: String?, hasSurfaceTarget: Bool) -> CmuxSubmissionPlan {
        .sendThenKey(text: text, key: "enter")
    }

    // MARK: - Diagnostics (for Settings → cmux Connection tab)

    /// A snapshot of everything the cmux-relay path needs to work. Consumed by
    /// the cmux connection diagnostic UI in System Settings.
    struct ConnectionProbe: Sendable {
        let cmuxBinaryInstalled: Bool
        /// The exact path the relay resolved cmux to (or nil if not found).
        /// Surfaced in the diagnostic row so a user can confirm *which* cmux
        /// install the relay is using — the crux of the #49/#62 reports.
        let cmuxBinaryPath: String?
        let accessibilityGranted: Bool
        let claudeSessionCount: Int
        /// Automation (AppleEvents) permission for the first running terminal.
        /// nil = no supported terminal running, or not yet prompted.
        let automationGranted: Bool?
        /// Which terminal was probed + human-readable status. Surfaced in the
        /// status row so users can tell "cmux granted" from "cmux not
        /// prompted" at a glance.
        let automationDetail: String
        /// First detected cmux-hosted target (workspaceId, surfaceId?), used by
        /// the "Test send" button. nil if no cmux-hosted Claude is running.
        let testTarget: (workspaceId: String, surfaceId: String?)?
    }

    /// Run all the health checks a user would need to diagnose "why isn't my
    /// phone message landing in cmux". Non-invasive — does not write to any
    /// terminal.
    func probeConnection() async -> ConnectionProbe {
        // Force a re-scan so the diagnostic reflects the live state (the user
        // may have just installed/opened cmux and tapped "Refresh").
        let cmuxResolved = CmuxBinary.resolvedPath(forceRefresh: true)
        let axOk = AXIsProcessTrusted()
        let procs = await listClaudeProcesses()
        var firstTarget: (workspaceId: String, surfaceId: String?)?
        for proc in procs {
            if let t = await readCmuxIDs(forPid: proc.pid) {
                firstTarget = t
                break
            }
        }
        let (autoOk, autoDetail) = probeAutomationPermission()
        return ConnectionProbe(
            cmuxBinaryInstalled: cmuxResolved != nil,
            cmuxBinaryPath: cmuxResolved,
            accessibilityGranted: axOk,
            claudeSessionCount: procs.count,
            automationGranted: autoOk,
            automationDetail: autoDetail,
            testTarget: firstTarget
        )
    }

    /// Non-invasive probe for Automation (AppleEvents) TCC permission. Uses
    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`
    /// so it never triggers the TCC dialog — the dedicated "Request
    /// Automation permission" button is responsible for that.
    ///
    /// We check cmux first (the primary relay target), then fall back to
    /// other supported terminals. Returns `(granted, detail)`:
    /// - `(true, "cmux ✓")`   — granted
    /// - `(false, "cmux — err=-1743")` — explicitly denied
    /// - `(nil, "cmux — not yet prompted")` — consent would be required
    /// - `(nil, "...")` — no supported terminal running
    private func probeAutomationPermission() -> (granted: Bool?, detail: String) {
        let candidates: [(bundleId: String, label: String)] = [
            ("com.cmuxterm.app", "cmux"),
            ("com.googlecode.iterm2", "iTerm"),
            ("com.mitchellh.ghostty", "Ghostty"),
            ("com.apple.Terminal", "Terminal")
        ]

        // Build the AEAddressDesc once for Code Island — this is the ASKING app.
        // AEDeterminePermissionToAutomateTarget checks whether this app (Code Island)
        // is authorized to send events TO each terminal target below.
        let codeIslandBundleId = Bundle.main.bundleIdentifier ?? "com.codeisland.app"
        var requestorAddr = AEAddressDesc()
        let requestorData = Data(codeIslandBundleId.utf8)
        let requestorStatus: OSErr = requestorData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSErr in
            guard let baseAddress = bytes.baseAddress else { return OSErr(-1) }
            return AECreateDesc(DescType(typeApplicationBundleID),
                                baseAddress,
                                bytes.count,
                                &requestorAddr)
        }
        guard requestorStatus == OSErr(noErr) else {
            return (nil, L10n.automationUnknown)
        }
        defer { AEDisposeDesc(&requestorAddr) }

        for (bundleId, label) in candidates {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else { continue }

            // Build the target address for this terminal — this is the TARGET app.
            // The AEAddressDesc represents the recipient of AppleEvents.
            var targetAddr = AEAddressDesc()
            let targetData = Data(bundleId.utf8)
            let createStatus: OSErr = targetData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSErr in
                guard let baseAddress = bytes.baseAddress else { return OSErr(-1) }
                return AECreateDesc(DescType(typeApplicationBundleID),
                                    baseAddress,
                                    bytes.count,
                                    &targetAddr)
            }
            guard createStatus == OSErr(noErr) else {
                return (nil, "\(label) — AECreateDesc err=\(createStatus)")
            }
            defer { AEDisposeDesc(&targetAddr) }

            // Check: "Can this app automate the target terminal?"
            let status = AEDeterminePermissionToAutomateTarget(
                &targetAddr,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                false
            )
            switch status {
            case noErr:
                return (true, "\(label) ✓")
            case OSStatus(errAEEventNotPermitted):
                return (false, "\(label) — denied (err=-1743)")
            case -1744: // errAEEventWouldRequireUserConsent
                return (nil, "\(label) — not yet prompted")
            default:
                return (nil, "\(label) — status=\(status)")
            }
        }
        return (nil, L10n.automationUnknown)
    }

    /// Proactively trigger the macOS Automation TCC prompt by dispatching a
    /// harmless `activate` AppleEvent to the first running supported terminal.
    /// Without this, the user never sees the permission dialog until they
    /// actually try to send a message — and by then the relay has already
    /// silently failed. Called from the Settings → cmux Connection tab.
    ///
    /// Uses `NSAppleScript` (in-process) rather than spawning `osascript` as
    /// a subprocess. Subprocess dispatch can confuse TCC attribution on some
    /// macOS builds — the event is blamed on osascript (which already has
    /// Automation entries from unrelated apps) instead of the parent, and no
    /// prompt ever fires. In-process NSAppleScript runs inside Code Island's
    /// own code signature, so TCC reliably attributes to `com.codeisland.app`
    /// and shows the dialog on first use.
    ///
    /// Returns `(ok, detail)` — on failure, `detail` contains the raw
    /// NSAppleScriptErrorNumber so we can diagnose TCC edge cases from the
    /// UI without opening Console.
    func requestAutomationPermission() async -> (ok: Bool, detail: String) {
        // Probe order matches TerminalJumper — cmux first since it's the
        // primary relay target.
        let candidates: [(bundleId: String, label: String)] = [
            ("com.cmuxterm.app", "cmux"),
            ("com.googlecode.iterm2", "iTerm"),
            ("com.mitchellh.ghostty", "Ghostty"),
            ("com.apple.Terminal", "Terminal")
        ]
        for (bundleId, label) in candidates {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else { continue }

            let source = "tell application id \"\(bundleId)\" to activate"
            let script = NSAppleScript(source: source)
            var errorInfo: NSDictionary?
            _ = script?.executeAndReturnError(&errorInfo)

            if errorInfo == nil {
                return (true, "\(L10n.requestAutomationPrompted) (\(label))")
            }
            // Surface the raw error so we can tell "prompt shown, user denied"
            // (err -1743) from "script parse failure" from "target not
            // running" — they all need different fixes.
            let errNum = (errorInfo?["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let errMsg = (errorInfo?["NSAppleScriptErrorMessage"] as? String) ?? "?"
            return (false, "\(L10n.requestAutomationDenied) (\(label) · err=\(errNum) · \(errMsg))")
        }
        return (false, L10n.requestAutomationNoTerminal)
    }

    /// Send a fixed diagnostic probe line to the first detected cmux target.
    /// Returns a human-readable result string that the UI can show directly.
    func testSendDiagnostic() async -> (ok: Bool, detail: String) {
        let probe = await probeConnection()
        guard probe.cmuxBinaryInstalled else {
            DebugLogger.log("TestSend", "FAILED: cmux binary not installed")
            return (false, L10n.cmuxBinaryMissing)
        }
        guard let (wsId, surfId) = probe.testTarget else {
            DebugLogger.log("TestSend", "FAILED: no cmux-hosted Claude target (sessions=\(probe.claudeSessionCount))")
            return (false, L10n.testSendNoTarget)
        }
        // Deliberately empty-ish payload that won't spam the user's terminal:
        // a single `#` comment line which most shells treat as a no-op.
        var args = ["send", "--workspace", wsId]
        if let surfId { args += ["--surface", surfId] }
        args += ["--", "# CodeIsland probe\r"]
        let result = await cmuxRun(args)
        if result != nil {
            DebugLogger.log("TestSend", "ok ws=\(wsId.prefix(8)) surf=\(surfId?.prefix(8).description ?? "-")")
            return (true, "\(L10n.testSendSuccess) — ws=\(wsId.prefix(8)) surf=\(surfId?.prefix(8).description ?? "-")")
        } else {
            // cmuxRun already logged the timeout/non-zero exit detail ([Shell]).
            // The #1 cause of a hard send failure (issue #95) is cmux's socket
            // ACL: `socketControlMode` defaults to `cmuxOnly`, which rejects any
            // process outside cmux's own tree — Mio Island included — with a
            // `Broken pipe`. That looks identical to a generic error, so users
            // (and their AIs) chase Automation/TCC red herrings for an hour.
            // Detect the ACL deterministically from cmux's own config and say so.
            let mode = Self.cmuxSocketControlMode()
            if mode != "automation" {
                DebugLogger.log("TestSend", "FAILED: likely socket ACL (socketControlMode=\(mode ?? "default:cmuxOnly")) ws=\(wsId.prefix(8)) surf=\(surfId?.prefix(8).description ?? "-")")
                return (false, L10n.testSendFailedSocketACL)
            }
            DebugLogger.log("TestSend", "FAILED: cmux send returned error (socketControlMode=automation) ws=\(wsId.prefix(8)) surf=\(surfId?.prefix(8).description ?? "-")")
            return (false, L10n.testSendFailed)
        }
    }

    /// Read cmux's `automation.socketControlMode` from its on-disk config.
    /// Returns the configured mode string, or nil when the key/file is absent
    /// (cmux's own default is `cmuxOnly`, so nil should be treated as such).
    ///
    /// External apps can only drive `cmux send` when this is `automation`; the
    /// default `cmuxOnly` restricts the control socket to cmux's own process
    /// descendants and is the root cause of the #95 "injection always fails"
    /// report. Checked paths mirror cmux's config lookup.
    nonisolated static func cmuxSocketControlMode() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.config/cmux/cmux.json",
            home + "/Library/Application Support/cmux/cmux.json"
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let automation = json["automation"] as? [String: Any],
               let mode = automation["socketControlMode"] as? String {
                return mode
            }
            // File exists but doesn't pin the key → cmux applies its default.
            return nil
        }
        return nil
    }

    // MARK: - Relay entry points

    /// Send a text message to the terminal running the given session.
    func sendText(_ text: String, to session: SessionState) async -> Bool {
        let termApp = session.terminalApp?.lowercased() ?? ""

        // Try cmux first (most precise)
        if cmuxPath != nil {
            if await sendViaCmux(text, session: session) {
                return true
            }
        }

        // Try AppleScript for known terminals
        if termApp.contains("iterm") {
            return await sendViaAppleScript(text, script: """
                tell application "iTerm2"
                    tell current session of current tab of current window
                        write text "\(text.replacingOccurrences(of: "\"", with: "\\\""))"
                    end tell
                end tell
                """)
        }

        if termApp.contains("ghostty") {
            return await sendViaGhosttyDirect(text, cwd: session.cwd)
        }

        if termApp.contains("terminal") && !termApp.contains("wez") {
            return await sendViaAppleScript(text, script: """
                tell application "Terminal"
                    do script "\(text.replacingOccurrences(of: "\"", with: "\\\""))" in selected tab of front window
                end tell
                """)
        }

        Self.logger.warning("No supported terminal for session \(session.sessionId.prefix(8))")
        return false
    }

    /// Send text directly via cmux using a Claude session UUID + cwd, without needing
    /// a SessionState in SessionStore. Used when phone sends a message to a session
    /// CodeIsland isn't currently tracking locally.
    ///
    /// `livePid` is optional but strongly preferred — when SyncManager has a
    /// `SessionState` it can pass `session.pid`, which CodeIsland captured from
    /// the Claude process via `os.getppid()` in the hook script. That's the
    /// only 100% reliable identity, because it doesn't depend on argv parsing
    /// or cwd matching. argv/cwd fallbacks only kick in if the pid is missing
    /// or stale.
    func sendTextDirect(_ text: String, claudeUuid: String, cwd: String?, livePid: Int? = nil, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil, terminalApp: String? = nil) async -> Bool {
        let resolved = await resolveTerminalApp(terminalApp: terminalApp, claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId)

        if resolved == "cmux" {
            return await sendViaCmuxDirect(text, claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId, terminalApp: terminalApp)
        }

        return await sendViaTerminalFallback(text, cwd: cwd, terminalApp: resolved)
    }

    /// Send a single control key (escape, ctrl+c, enter, …) to the Claude terminal.
    /// Returns true if the cmux surface was found and send-key invoked.
    func sendControlKey(_ key: String, claudeUuid: String, cwd: String? = nil, livePid: Int? = nil, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil, terminalApp: String? = nil) async -> Bool {
        let resolved = await resolveTerminalApp(terminalApp: terminalApp, claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId)

        if resolved == "cmux" {
            if let (wsId, surfId) = await findCmuxTarget(claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId),
               let surfId {
                let result = await cmuxRun(["send-key", "--workspace", wsId, "--surface", surfId, "--", key])
                Self.logger.info("Sent key '\(key)' to cmux (ws=\(wsId.prefix(8)) surf=\(surfId.prefix(8))) result=\(result != nil)")
                return result != nil
            }
            return false
        }

        return await sendControlKeyViaTerminalFallback(key, cwd: cwd, terminalApp: resolved)
    }

    /// Snapshot the current cmux surface (visible pane + scrollback) as plain text.
    /// Used by the phone's "read screen" button so the user can check terminal state
    /// without injecting any input. Returns nil if the surface can't be located.
    func readScreen(claudeUuid: String, cwd: String? = nil, livePid: Int? = nil, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil, terminalApp: String? = nil, lines: Int = 500) async -> String? {
        let resolved = await resolveTerminalApp(terminalApp: terminalApp, claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId)

        if resolved == "cmux" {
            guard let (wsId, surfId) = await findCmuxTarget(claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId),
                  let surfId else {
                Self.logger.warning("readScreen: no cmux target for uuid=\(claudeUuid.prefix(8))")
                return nil
            }
            let raw = await cmuxRun(["read-screen", "--workspace", wsId, "--surface", surfId, "--scrollback", "--lines", "\(lines)"]) ?? ""
            let split = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
            let cleaned = cleanupOutputLines(split)
            return cleaned.isEmpty ? nil : cleaned
        }

        if resolved?.contains("ghostty") == true {
            return await readScreenViaGhostty(cwd: cwd, lines: lines)
        }

        Self.logger.warning("readScreen: unsupported terminal \(resolved ?? "nil")")
        return nil
    }

    /// Capture raw text from Ghostty via its native AppleScript action API.
    /// Returns raw text (no cleanup) for accurate diffing, or cleaned text for display.
    private func captureGhosttyScreen(cwd: String?) async -> String? {
        await activateGhostty(cwd: cwd)

        let pb = NSPasteboard.general
        let savedClipboardItems = Self.clonePasteboardItems(pb)

        pb.clearContents()

        // Ask Ghostty to write the visible screen as plain text. This avoids
        // Select All and bypasses System Events key synthesis, which does not
        // reliably trigger Ghostty's internal keybind handling.
        let ok = await performGhosttyAction("write_screen_file:copy,plain", cwd: cwd)

        guard ok else {
            Self.restorePasteboardItems(savedClipboardItems, to: pb)
            Self.logger.warning("captureGhosttyScreen: AppleScript failed")
            return nil
        }

        let clipboardString = await waitForPasteboardString(pb)
        let captured = Self.resolveGhosttyScreenCapture(clipboardString)

        Self.restorePasteboardItems(savedClipboardItems, to: pb)

        guard !captured.isEmpty else {
            Self.logger.warning("captureGhosttyScreen: clipboard empty after copy")
            return nil
        }

        Self.logger.info("captureGhosttyScreen: captured \(captured.count) chars")
        return captured
    }

    /// Read screen content from Ghostty — cleaned for display.
    private func readScreenViaGhostty(cwd: String?, lines: Int = 500) async -> String? {
        guard let raw = await captureGhosttyScreen(cwd: cwd) else { return nil }
        let allLines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        // Ghostty 1.3.x can return more than the viewport here; keep read-screen
        // bounded to a visible-window sized slice without affecting slash diffing.
        let visibleLineLimit = min(lines, 80)
        let trimmed = allLines.count > visibleLineLimit ? Array(allLines.suffix(visibleLineLimit)) : allLines
        let cleaned = cleanupOutputLines(trimmed)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Execute a Ghostty action directly through its AppleScript dictionary.
    private func performGhosttyAction(_ action: String, cwd: String?) async -> Bool {
        let actionLiteral = Self.appleScriptStringLiteral(action)
        let cwdBlock: String
        if let cwd, !cwd.isEmpty {
            cwdBlock = """
                set cwdNeedle to \(Self.appleScriptStringLiteral(cwd))
                repeat with candidateTerm in terminals
                    if (working directory of candidateTerm) contains cwdNeedle then
                        set targetTerm to contents of candidateTerm
                        exit repeat
                    end if
                end repeat
                """
        } else {
            cwdBlock = ""
        }

        return await runOsascript("""
            tell application "Ghostty"
                set targetTerm to missing value
                \(cwdBlock)
                if targetTerm is missing value then
                    try
                        set targetTerm to focused terminal of selected tab of front window
                    end try
                end if
                if targetTerm is missing value then
                    if (count of terminals) is 0 then return false
                    set targetTerm to item 1 of terminals
                end if
                if not (perform action \(actionLiteral) on targetTerm) then error "Ghostty action failed"
                delay 0.15
                return true
            end tell
            """)
    }

    private func waitForPasteboardString(_ pasteboard: NSPasteboard) async -> String {
        for _ in 0..<20 {
            if let value = pasteboard.string(forType: .string), !value.isEmpty {
                return value
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return pasteboard.string(forType: .string) ?? ""
    }

    private static func resolveGhosttyScreenCapture(_ clipboardString: String) -> String {
        let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fileContent = readGhosttyCaptureFile(atPath: trimmed) {
            return fileContent
        }
        return clipboardString
    }

    private static func readGhosttyCaptureFile(atPath path: String) -> String? {
        guard !path.isEmpty,
              !path.contains("\n"),
              !path.contains("\r") else { return nil }

        let url: URL
        if path.hasPrefix("file://"), let parsed = URL(string: path), parsed.isFileURL {
            url = parsed.standardizedFileURL
        } else {
            guard path.hasPrefix("/") else { return nil }
            url = URL(fileURLWithPath: path).standardizedFileURL
        }

        let filePath = url.path
        guard FileManager.default.isReadableFile(atPath: filePath),
              let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? NSNumber,
              size.uint64Value <= 5_000_000,
              let data = try? Data(contentsOf: url) else { return nil }

        return String(data: data, encoding: .utf8)
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func clonePasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let clone = NSPasteboardItem()
            var copiedAnyType = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                    copiedAnyType = true
                } else if let string = item.string(forType: type) {
                    clone.setString(string, forType: type)
                    copiedAnyType = true
                }
            }
            return copiedAnyType ? clone : nil
        }
    }

    private static func restorePasteboardItems(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// Capture the terminal output that appeared *after* a slash command was sent.
    /// Snapshots the pane before, sends the command, waits for output to settle,
    /// then diffs the two snapshots and returns only the new lines.
    ///
    /// Returns nil if we can't locate the cmux surface for this Claude session or
    /// capture fails.
    func sendSlashCommandAndCaptureOutput(_ command: String, claudeUuid: String, cwd: String? = nil, livePid: Int? = nil, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil, terminalApp: String? = nil, settleMs: UInt64 = 1500) async -> String? {
        let resolved = await resolveTerminalApp(terminalApp: terminalApp, claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId)

        if resolved == "cmux" {
            guard let (wsId, surfId) = await findCmuxTarget(claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId),
                  let surfId else {
                Self.logger.warning("captureOutput: no cmux target for uuid=\(claudeUuid.prefix(8))")
                return nil
            }

            let before = await cmuxRun(["read-screen", "--workspace", wsId, "--surface", surfId, "--scrollback", "--lines", "500"]) ?? ""
            let escaped = command.replacingOccurrences(of: "\n", with: "\r")
            _ = await cmuxRun(["send", "--workspace", wsId, "--surface", surfId, "--", "\(escaped)\r"])
            try? await Task.sleep(nanoseconds: settleMs * 1_000_000)
            let after = await cmuxRun(["read-screen", "--workspace", wsId, "--surface", surfId, "--scrollback", "--lines", "500"]) ?? ""

            let diff = diffTerminalSnapshots(before: before, after: after)
            return diff.isEmpty ? "" : diff
        }

        if resolved?.contains("ghostty") == true {
            // Send command via clipboard paste
            let sent = await sendViaGhosttyDirect(command, cwd: cwd)
            guard sent else { return nil }

            // Wait for output to render
            try? await Task.sleep(nanoseconds: settleMs * 1_000_000)

            // Capture screen and extract only content after the command
            guard let raw = await captureGhosttyScreen(cwd: cwd) else { return nil }
            let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

            // Find the LAST occurrence of the command in the output
            let cmdTrimmed = command.trimmingCharacters(in: .whitespaces)
            var anchorIdx: Int?
            for i in stride(from: lines.count - 1, through: 0, by: -1) {
                if lines[i].contains(cmdTrimmed) {
                    anchorIdx = i
                    break
                }
            }

            let newLines: [String]
            if let idx = anchorIdx, idx + 1 < lines.count {
                newLines = Array(lines.suffix(from: idx + 1))
            } else {
                // Fallback: last 30 lines
                newLines = Array(lines.suffix(30))
            }

            let cleaned = cleanupOutputLines(newLines)
            return cleaned.isEmpty ? "" : cleaned
        }

        Self.logger.warning("captureOutput: unsupported terminal \(resolved ?? "nil")")
        return nil
    }

    /// Extract the text that newly appeared in `after` relative to `before`.
    /// Strategy: find the last non-empty anchor line from `before` in `after`,
    /// return everything after it. Falls back to the trailing portion if no anchor.
    nonisolated private func diffTerminalSnapshots(before: String, after: String) -> String {
        let beforeLines = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let afterLines = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard !afterLines.isEmpty else { return "" }

        // Find an anchor: the last non-empty meaningful line from `before` that
        // also appears in `after`. Search from the end of `before` forward.
        let meaningful = beforeLines.reversed().first { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.count > 4
        }

        if let anchor = meaningful,
           let idx = afterLines.lastIndex(of: anchor) {
            let newLines = Array(afterLines.suffix(from: afterLines.index(after: idx)))
            return cleanupOutputLines(newLines)
        }

        // Fallback: return the last N lines of the after snapshot
        let trailing = Array(afterLines.suffix(40))
        return cleanupOutputLines(trailing)
    }

    /// Normalize captured terminal lines: trim trailing whitespace, drop leading
    /// blank lines, collapse long runs of empty lines, cap total length.
    /// Regex to strip ANSI escape sequences — compiled once.
    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\\x1b\\[[0-9;]*[A-Za-z]|\\x1b\\][^\\x07]*\\x07|\\x1b[()][A-Za-z0-9]", options: [])

    nonisolated private func cleanupOutputLines(_ lines: [String]) -> String {
        var cleaned: [String] = []
        var blankRun = 0
        for rawLine in lines {
            var line = rawLine.replacingOccurrences(of: "\u{00A0}", with: " ")
            line = Self.ansiPattern.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 && !cleaned.isEmpty {
                    cleaned.append("")
                }
            } else {
                blankRun = 0
                cleaned.append(line)
            }
        }
        // Trim leading/trailing blanks
        while let first = cleaned.first, first.isEmpty { cleaned.removeFirst() }
        while let last = cleaned.last, last.isEmpty { cleaned.removeLast() }
        var joined = cleaned.joined(separator: "\n")
        if joined.count > 4000 {
            joined = String(joined.suffix(4000))
        }
        return joined
    }

    /// Paste one or more images into the terminal running the given Claude session,
    /// then send any accompanying text. Uses NSPasteboard + CGEvent Cmd+V via cmux focus.
    /// Returns true if at least the focusing + paste attempts succeeded.
    func sendImagesAndText(images: [Data], text: String, claudeUuid: String, cwd: String? = nil, livePid: Int? = nil, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil, terminalApp: String? = nil) async -> Bool {
        let resolved = await resolveTerminalApp(terminalApp: terminalApp, claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId)

        if resolved != "cmux" {
            return await sendImagesViaTerminalFallback(images: images, text: text, cwd: cwd, terminalApp: resolved)
        }

        guard let (wsId, surfId) = await findCmuxTarget(claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId),
              let surfId else {
            Self.logger.warning("sendImagesAndText: cmux resolved but no target found")
            return false
        }

        // Accessibility self-check — CGEvent and System Events keystrokes both
        // silently fail without this permission.
        let axTrusted = AXIsProcessTrusted()
        Self.logger.info("Accessibility trusted=\(axTrusted)")

        // 1. Switch cmux internally to the target surface. `focus-panel` is the
        //    correct command — cmux calls surfaces "panels" in CLI-speak.
        _ = await cmuxRun(["focus-panel", "--panel", surfId, "--workspace", wsId])

        // 2. Bring cmux.app to the foreground. AppleScript is more reliable than
        //    NSRunningApplication here (the latter sometimes fails to locate cmux).
        _ = await runOsascript(#"tell application id "com.cmuxterm.app" to activate"#)

        // Wait up to 1s for cmux to actually become frontmost.
        var frontOk = false
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.cmuxterm.app" {
                frontOk = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Self.logger.info("cmux frontmost=\(frontOk)")

        // Extra settle time after cmux is frontmost.
        try? await Task.sleep(nanoseconds: 200_000_000)

        for (idx, imgData) in images.enumerated() {
            writeImageToPasteboard(imgData)
            // Ensure pasteboard is settled before firing the key.
            try? await Task.sleep(nanoseconds: 120_000_000)
            // Use AppleScript keystroke as the primary path — it's more reliable than
            // raw CGEvent in many window server configurations. Fall back to CGEvent.
            if !(await postCmdVViaAppleScript()) {
                Self.logger.info("AppleScript paste failed, falling back to CGEvent")
                postCmdV()
            }
            // Delay between multi-image pastes so Claude can ingest each.
            if idx < images.count - 1 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        // Settle before sending the accompanying text so it doesn't race the paste.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Text goes through cmux's own channel (bypasses the pasteboard path).
        let trailing = text.isEmpty
            ? "\r"
            : "\(text.replacingOccurrences(of: "\n", with: "\r"))\r"
        _ = await cmuxRun(["send", "--workspace", wsId, "--surface", surfId, "--", trailing])

        Self.logger.info("Pasted \(images.count) image(s) + text via cmux (ws=\(wsId.prefix(8)) surf=\(surfId.prefix(8)))")
        return true
    }

    /// Place raw image bytes on the general pasteboard in the formats most terminals
    /// expect. We use the native format (jpeg/png) and also include TIFF as a lingua
    /// franca fallback.
    nonisolated private func writeImageToPasteboard(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // Decode so we can emit a TIFF representation too.
        guard let image = NSImage(data: data) else {
            // Fallback: just stamp the raw bytes under a guess.
            pb.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
            return
        }

        // Write NSImage first — terminals that register for image types pick this up.
        pb.writeObjects([image])

        // Also write the raw bytes under both jpeg and tiff types for maximum compat.
        pb.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    /// Post a Cmd+V key event via CGEvent. Requires Accessibility permission on macOS.
    nonisolated private func postCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9 // "V"
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    /// Simulate Cmd+V via AppleScript System Events. Returns true on success.
    nonisolated private func postCmdVViaAppleScript() async -> Bool {
        return await runOsascript(#"tell application "System Events" to keystroke "v" using {command down}"#)
    }

    /// Run an AppleScript snippet via osascript with a hard timeout. Silently
    /// returns `false` on TCC denial, hang, or non-zero exit — callers are
    /// expected to surface permission problems via the Settings UI, not this
    /// return value alone.
    @discardableResult
    nonisolated private func runOsascript(_ script: String) async -> Bool {
        let (_, ok) = await runShellWithTimeout("/usr/bin/osascript", ["-e", script], timeout: 5.0)
        return ok
    }

    private func sendViaCmuxDirect(_ text: String, claudeUuid: String, cwd: String?, livePid: Int?, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil, terminalApp: String? = nil) async -> Bool {
        // Resolution order (in increasing fallback unreliability):
        //   1. **Live PID from CodeIsland's hook tracking** — captured at hook
        //      time via `os.getppid()`, this is the actual Claude process for
        //      the conversation. Read CMUX_*_ID env vars from /proc and we're
        //      done. This works regardless of `claude --resume` rotating the
        //      live session-id, and it works for multiple sessions in the same
        //      cwd. THE preferred path.
        //   2. argv match by --session-id (works only for fresh, non-resumed
        //      sessions whose argv id == JSONL filename).
        //   3. cwd-scoped scan (heuristic — picks highest pid when multiple).
        guard let (wsId, surfId) = await findCmuxTarget(claudeUuid: claudeUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWorkspaceId, cmuxSurfaceId: cmuxSurfaceId) else {
            Self.logger.warning("No cmux-hosted claude process for uuid=\(claudeUuid.prefix(8)) cwd=\(cwd ?? "nil") pid=\(livePid?.description ?? "nil") — session is orphaned, in a non-cmux terminal, or on another machine")
            return false
        }

        var args = ["send"]
        args += ["--workspace", wsId]
        if let surfId { args += ["--surface", surfId] }
        let plan = Self.cmuxSubmissionPlan(text: text, terminalApp: terminalApp, hasSurfaceTarget: surfId != nil)
        switch plan {
        case .appendReturn(let payload):
            args += ["--", payload]
            guard await cmuxRun(args) != nil else {
                Self.logger.error("cmux send failed for workspace=\(wsId)")
                return false
            }
        case .sendThenKey(let payload, let key):
            args += ["--", payload]
            guard await cmuxRun(args) != nil else {
                Self.logger.error("cmux send failed for workspace=\(wsId)")
                return false
            }
            // Codex ingests the pasted text on its own raw-mode event loop;
            // settle briefly so the submit key doesn't land before the composer
            // holds the text (mirrors the image-path paste settle on line ~751).
            try? await Task.sleep(nanoseconds: 150_000_000)
            // `cmux send-key` defaults `--surface` to the workspace's active
            // surface, so we no longer bail when surfId is nil: the text `send`
            // above already landed on that active surface. Pass the surface
            // explicitly when we have one for precision.
            var keyArgs = ["send-key", "--workspace", wsId]
            if let surfId { keyArgs += ["--surface", surfId] }
            keyArgs += ["--", key]
            guard await cmuxRun(keyArgs) != nil else {
                Self.logger.error("cmux send-key '\(key)' failed for workspace=\(wsId)")
                return false
            }
        }
        Self.logger.info("Sent message via cmux (workspace=\(wsId.prefix(8)) surface=\(surfId?.prefix(8).description ?? "-"))")
        return true
    }

    /// Top-level resolver. Tries the most reliable identity first (live PID
    /// from CodeIsland's hook tracking), then falls back to argv match, then
    /// to cwd-scoped scanning.
    nonisolated private func findCmuxTarget(claudeUuid: String, cwd: String?, livePid: Int?, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil) async -> (workspaceId: String, surfaceId: String?)? {
        // Pass 0 (preferred): cmux IDs captured by the hook script from its own
        // `os.environ`. This is the most reliable path because it doesn't
        // depend on `ps -E`, which hides env vars for hardened-runtime Claude
        // processes on modern macOS.
        if let wsId = cmuxWorkspaceId, !wsId.isEmpty {
            return (wsId, (cmuxSurfaceId?.isEmpty == false) ? cmuxSurfaceId : nil)
        }
        // Pass 1: hook-recorded live pid. Second-most reliable, but depends on
        // `ps -E -p <pid>` exposing CMUX env vars (works on older macOS /
        // non-hardened builds).
        if let livePid, let target = await readCmuxIDs(forPid: livePid) {
            return target
        }
        // Pass 2: argv match by --session-id or positional UUID, then cwd fallback.
        return await findCmuxTargetForClaudeSession(uuid: claudeUuid, cwd: cwd)
    }

    /// Look up a cmux workspace+surface for the live Claude process backing the
    /// given session UUID. Tries argv match first (works when JSONL id == live
    /// id), falls back to cwd-scoped scan when the conversation was resumed
    /// (rotating live id) or when CodeIsland is reporting the JSONL filename.
    nonisolated private func findCmuxTargetForClaudeSession(uuid: String, cwd: String?) async -> (workspaceId: String, surfaceId: String?)? {
        let candidates = await listClaudeProcesses()
        if candidates.isEmpty { return nil }

        // Pass 1: exact argv match by --session-id
        if let exact = candidates.first(where: { $0.sessionId == uuid }),
           let target = await readCmuxIDs(forPid: exact.pid) {
            return target
        }

        // Pass 2: cwd-scoped fallback. Restrict to processes whose cwd matches
        // the session's cwd AND who have CMUX env vars (i.e. are inside a cmux
        // pane — no point routing to an iTerm window we can't drive).
        guard let cwd, !cwd.isEmpty else {
            DebugLogger.log("TerminalWriter", "findCmuxTarget: argv miss for uuid=\(uuid.prefix(8)) and no cwd to fall back on")
            return nil
        }

        var cwdMatched: [(pid: Int, target: (workspaceId: String, surfaceId: String?))] = []
        for proc in candidates where proc.cwd == cwd {
            if let target = await readCmuxIDs(forPid: proc.pid) {
                cwdMatched.append((proc.pid, target))
            }
        }

        guard !cwdMatched.isEmpty else {
            DebugLogger.log("TerminalWriter", "findCmuxTarget: no cwd-matching cmux-hosted claude in \(cwd)")
            return nil
        }

        if cwdMatched.count > 1 {
            DebugLogger.log("TerminalWriter", "findCmuxTarget: \(cwdMatched.count) candidates in cwd=\(cwd) — picking highest pid as heuristic")
        }
        return cwdMatched.max { $0.pid < $1.pid }?.target
    }

    /// One running claude process — its pid, the session-id from argv, and its cwd.
    nonisolated private struct ClaudeProcessInfo {
        let pid: Int
        let sessionId: String
        let cwd: String?
    }

    /// Enumerate every running claude process.
    ///
    /// Primary path: read session metadata from `~/.claude/sessions/{pid}.json`
    /// (modern Claude Code 0.x+ stores pid, sessionId, cwd, startedAt there).
    ///
    /// Fallback: parse `ps -Axww` output for older Claude versions that expose
    /// session UUIDs as `--session-id <uuid>` or as the first positional arg.
    nonisolated private func listClaudeProcesses() async -> [ClaudeProcessInfo] {
        let fromConfig = await discoverClaudeSessionsFromConfig()
        if !fromConfig.isEmpty {
            return fromConfig
        }
        return await listClaudeProcessesFromPs()
    }

    /// Primary: read session info from `~/.claude/sessions/*.json`.
    /// Each file contains `{ "pid", "sessionId", "cwd", "startedAt", "kind", "entrypoint" }`.
    /// Verifies the pid is still running via `ps -p {pid} -o pid=` before including it.
    nonisolated private func discoverClaudeSessionsFromConfig() async -> [ClaudeProcessInfo] {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var processes: [ClaudeProcessInfo] = []
        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  Self.isUuidLike(sessionId) else { continue }

            // Verify the process is still alive using kill(0) signal check.
            // Faster and more reliable than spawning /bin/ps subprocess.
            guard kill(Int32(pid), 0) == 0 else { continue }

            // Prefer cwd from the JSON; fall back to lsof if absent
            let cwd: String
            if let c = json["cwd"] as? String { cwd = c } else { cwd = await lsofCwd(pid: pid) ?? "" }
            processes.append(ClaudeProcessInfo(pid: pid, sessionId: sessionId, cwd: cwd))
        }
        return processes
    }

    /// Fallback: parse `ps -Axww` output for older Claude Code versions (pre-0.x)
    /// that expose session UUIDs on the command line.
    nonisolated private func listClaudeProcessesFromPs() async -> [ClaudeProcessInfo] {
        let (out, ok) = await runShellWithTimeout("/bin/ps", ["-Axww", "-o", "pid=,command="], timeout: 3.0)
        guard ok, let text = out else { return [] }

        var processes: [ClaudeProcessInfo] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("/claude") || trimmed.contains(" claude ") else { continue }

            let firstSpace = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
            let pidStr = String(trimmed[..<firstSpace])
            guard let pid = Int(pidStr) else { continue }

            var sid: String?

            // Format 1: --session-id <uuid>
            if let sidRange = trimmed.range(of: "--session-id ") {
                let after = trimmed[sidRange.upperBound...]
                let endIdx = after.firstIndex(of: " ") ?? after.endIndex
                let candidate = String(after[..<endIdx])
                if Self.isUuidLike(candidate) {
                    sid = candidate
                }
            }

            // Format 2: claude <uuid> … (UUID is first positional arg after the binary path)
            if sid == nil {
                let afterPid = trimmed[firstSpace...].drop(while: { $0 == " " })
                let tokens = afterPid.split(separator: " ", omittingEmptySubsequences: true)
                if tokens.count >= 2,
                   tokens[0].hasSuffix("claude") || tokens[0] == "claude",
                   Self.isUuidLike(String(tokens[1])) {
                    sid = String(tokens[1])
                }
            }

            guard let resolvedSid = sid else { continue }
            let cwd = await lsofCwd(pid: pid)
            processes.append(ClaudeProcessInfo(pid: pid, sessionId: resolvedSid, cwd: cwd))
        }
        return processes
    }

    /// UUID v4 shape: 8-4-4-4-12 hex chars. We don't care about version bits,
    /// we just want to avoid matching random positional args as "the UUID".
    nonisolated private static func isUuidLike(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        let parts = s.split(separator: "-")
        guard parts.count == 5 else { return false }
        let expected = [8, 4, 4, 4, 12]
        for (i, p) in parts.enumerated() {
            if p.count != expected[i] { return false }
            if !p.allSatisfy({ $0.isHexDigit }) { return false }
        }
        return true
    }

    nonisolated private func lsofCwd(pid: Int) async -> String? {
        let (out, ok) = await runShellWithTimeout("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"], timeout: 2.0)
        guard ok, let text = out else { return nil }
        // Output format (-Fn): "p<pid>\nf<cwd>\nn<path>\n"
        for line in text.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// Read CMUX_WORKSPACE_ID and CMUX_SURFACE_ID env vars from a running pid.
    /// Returns nil if the pid is gone, has no CMUX_WORKSPACE_ID, or ps fails.
    /// Uses `-Eww` to prevent macOS ps from truncating long env lines — without
    /// `-ww`, CMUX env vars near the end of the environment get cut off and we
    /// return nil incorrectly.
    nonisolated private func readCmuxIDs(forPid pid: Int) async -> (workspaceId: String, surfaceId: String?)? {
        let (out, ok) = await runShellWithTimeout("/bin/ps", ["-Eww", "-p", "\(pid)", "-o", "command="], timeout: 2.0)
        guard ok, let envLine = out else { return nil }

        var wsId: String?
        var surfId: String?
        for token in envLine.split(separator: " ") {
            if token.hasPrefix("CMUX_WORKSPACE_ID=") {
                wsId = String(token.dropFirst("CMUX_WORKSPACE_ID=".count))
            } else if token.hasPrefix("CMUX_SURFACE_ID=") {
                surfId = String(token.dropFirst("CMUX_SURFACE_ID=".count))
            }
        }
        guard let wsId else { return nil }
        return (wsId, surfId)
    }

    // MARK: - cmux

    private func sendViaCmux(_ text: String, session: SessionState) async -> Bool {
        let dirName = URL(fileURLWithPath: session.cwd).lastPathComponent
        let sid = String(session.sessionId.prefix(8))

        // Find workspace
        guard let wsOutput = await cmuxRun(["list-workspaces"]) else { return false }

        var targetWsRef: String?
        for wsLine in wsOutput.components(separatedBy: "\n") where !wsLine.isEmpty {
            guard let wsRef = wsLine.components(separatedBy: " ").first(where: { $0.hasPrefix("workspace:") }) else { continue }

            // Fast path: cmux often puts the Claude UUID and/or project name directly
            // in the workspace TITLE (e.g. `workspace:1  server · <title> · 6da6225e-…`),
            // while `list-pane-surfaces` may only show a short surface name. Check the
            // workspace line itself first.
            if wsLine.contains(sid) || wsLine.contains(dirName) {
                targetWsRef = wsRef
                break
            }

            // Fall back to matching inside the surface output.
            guard let surfOutput = await cmuxRun(["list-pane-surfaces", "--workspace", wsRef]) else { continue }
            if surfOutput.contains(sid) || surfOutput.contains(dirName) {
                targetWsRef = wsRef
                break
            }
        }

        guard let wsRef = targetWsRef else {
            Self.logger.warning("No matching cmux workspace for sid=\(sid, privacy: .public) dir=\(dirName, privacy: .public)")
            return false
        }

        // Send text + Enter
        let escaped = text.replacingOccurrences(of: "\n", with: "\r")
        _ = await cmuxRun(["send", "--workspace", wsRef, "--", "\(escaped)\r"])
        Self.logger.info("Sent message to cmux workspace \(wsRef, privacy: .public)")
        return true
    }

    /// Invoke the cmux CLI with a hard timeout. Returns nil on launch failure,
    /// non-zero exit, or timeout. All cmux calls MUST go through here — the
    /// previous raw Process.waitUntilExit could freeze the main thread when
    /// cmux became unresponsive (main cause of the "CodeIsland 卡死" reports).
    nonisolated private func cmuxRun(_ args: [String]) async -> String? {
        guard let path = cmuxPath else {
            DebugLogger.log("Cmux", "cmux binary not found in any known path — relay skipped")
            return nil
        }
        let (out, ok) = await runShellWithTimeout(path, args, timeout: 5.0)
        return ok ? out : nil
    }

    // MARK: - AppleScript

    /// Run an AppleScript snippet via osascript with a hard timeout. Like
    /// `cmuxRun`, this used to be a synchronous waitUntilExit which would
    /// freeze the UI if the user had not granted the Automation permission
    /// (TCC would block the AppleEvent dispatch indefinitely on some builds).
    private func sendViaAppleScript(_ text: String, script: String) async -> Bool {
        let (_, ok) = await runShellWithTimeout("/usr/bin/osascript", ["-e", script], timeout: 5.0)
        if ok {
            Self.logger.info("Sent message via AppleScript")
        }
        return ok
    }

    // MARK: - Terminal Routing & Fallbacks

    /// Decide which terminal backend to use for a given session.
    /// Priority: cmux target → explicit terminalApp → running terminal probe.
    private func resolveTerminalApp(terminalApp: String?, claudeUuid: String, cwd: String?, livePid: Int?, cmuxWorkspaceId: String? = nil, cmuxSurfaceId: String? = nil) async -> String? {
        // Check if the process lives inside cmux (has CMUX_WORKSPACE_ID env var or direct IDs)
        let hasCmuxTarget = await findCmuxTarget(
            claudeUuid: claudeUuid,
            cwd: cwd,
            livePid: livePid,
            cmuxWorkspaceId: cmuxWorkspaceId,
            cmuxSurfaceId: cmuxSurfaceId
        ) != nil
        return Self.preferredTerminalBackend(
            terminalApp: terminalApp,
            hasCmuxTarget: hasCmuxTarget,
            detectedFallback: detectRunningTerminal()
        )
    }

    /// Check which supported terminal is currently running (excluding cmux).
    private func detectRunningTerminal() -> String? {
        let candidates: [(bundleId: String, name: String)] = [
            ("com.mitchellh.ghostty", "ghostty"),
            ("com.googlecode.iterm2", "iterm2"),
            ("com.apple.Terminal", "terminal")
        ]
        for (bundleId, name) in candidates {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
                return name
            }
        }
        return nil
    }

    /// Send text via the appropriate non-cmux terminal.
    private func sendViaTerminalFallback(_ text: String, cwd: String?, terminalApp: String?) async -> Bool {
        let app = terminalApp ?? ""

        if app.contains("ghostty") {
            return await sendViaGhosttyDirect(text, cwd: cwd)
        }

        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")

        if app.contains("iterm") {
            return await sendViaAppleScript(text, script: """
                tell application "iTerm2"
                    tell current session of current tab of current window
                        write text "\(escaped)"
                    end tell
                end tell
                """)
        }

        if app.contains("terminal") && !app.contains("wez") {
            return await sendViaAppleScript(text, script: """
                tell application "Terminal"
                    do script "\(escaped)" in selected tab of front window
                end tell
                """)
        }

        Self.logger.warning("No supported terminal for fallback (detected=\(app))")
        return false
    }

    /// Focus the Ghostty terminal matching `cwd`, then type text + Enter.
    private func sendViaGhosttyDirect(_ text: String, cwd: String?) async -> Bool {
        await activateGhostty(cwd: cwd)

        // Use clipboard to support CJK and special characters (keystroke only works with ASCII)
        let pb = NSPasteboard.general
        let oldContents = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let ok = await runOsascript("""
            delay 0.3
            tell application "System Events"
                tell process "Ghostty"
                    keystroke "v" using {command down}
                    delay 0.2
                    key code 36
                end tell
            end tell
            """)

        // Restore previous clipboard content
        if let old = oldContents {
            pb.clearContents()
            pb.setString(old, forType: .string)
        }
        if ok {
            Self.logger.info("Sent message via Ghostty (cwd=\(cwd?.suffix(20).description ?? "nil"))")
        }
        return ok
    }

    /// Focus a Ghostty terminal whose working directory matches `cwd`, then activate.
    /// Combines cwd-matching + activate into a single osascript call.
    private func activateGhostty(cwd: String?) async {
        let cwdBlock: String
        if let cwd = cwd, !cwd.isEmpty {
            let escapedCwd = cwd.replacingOccurrences(of: "\"", with: "\\\"")
            cwdBlock = """
                set matches to every terminal whose working directory contains "\(escapedCwd)"
                if (count of matches) > 0 then
                    focus (item 1 of matches)
                end if
                """
        } else {
            cwdBlock = ""
        }
        _ = await runOsascript("""
            tell application "Ghostty"
                \(cwdBlock)
                activate
            end tell
            """)
    }

    /// Send a control key to a non-cmux terminal via System Events key codes.
    private func sendControlKeyViaTerminalFallback(_ key: String, cwd: String?, terminalApp: String?) async -> Bool {
        let app = terminalApp ?? ""
        guard app.contains("ghostty") || app.contains("iterm") || app.contains("terminal") else {
            Self.logger.warning("sendControlKey: no supported terminal for fallback (detected=\(app))")
            return false
        }

        if app.contains("ghostty") {
            await activateGhostty(cwd: cwd)
        }

        // Determine the System Events process name for targeting
        let processName: String
        if app.contains("ghostty") { processName = "Ghostty" }
        else if app.contains("iterm") { processName = "iTerm2" }
        else { processName = "Terminal" }

        // ctrl+<char> modifier combination
        let lower = key.lowercased()
        if lower.hasPrefix("ctrl+") || lower.hasPrefix("ctrl-") {
            let char = String(key.dropFirst(5))
            let escapedChar = char.replacingOccurrences(of: "\"", with: "\\\"")
            return await runOsascript("""
                tell application "System Events"
                    tell process "\(processName)"
                        keystroke "\(escapedChar)" using {control down}
                    end tell
                end tell
                """)
        }

        // Named key → macOS key code
        let keyCode: Int? = switch lower {
        case "escape": 53
        case "enter", "return": 36
        case "tab": 48
        case "up": 126
        case "down": 125
        case "left": 123
        case "right": 124
        case "backspace", "delete": 51
        case "space": 49
        default: nil
        }

        if let code = keyCode {
            let ok = await runOsascript("""
                tell application "System Events"
                    tell process "\(processName)"
                        key code \(code)
                    end tell
                end tell
                """)
            Self.logger.info("Sent key '\(key)' (code=\(code)) to \(processName) result=\(ok)")
            return ok
        }

        Self.logger.warning("sendControlKey: unmapped key '\(key)' for terminal fallback")
        return false
    }

    /// Paste images + text into a non-cmux terminal (Ghostty).
    private func sendImagesViaTerminalFallback(images: [Data], text: String, cwd: String?, terminalApp: String?) async -> Bool {
        let app = (terminalApp ?? detectRunningTerminal())?.lowercased() ?? ""
        guard app.contains("ghostty") else {
            Self.logger.warning("sendImagesViaTerminalFallback: unsupported terminal \(app)")
            return false
        }

        let axTrusted = AXIsProcessTrusted()
        Self.logger.info("Ghostty image paste: Accessibility trusted=\(axTrusted)")

        await activateGhostty(cwd: cwd)

        // Wait for Ghostty to become frontmost
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.mitchellh.ghostty" { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Paste each image via pasteboard + Ctrl+V (Claude Code uses Ctrl+V for image paste)
        for (idx, imgData) in images.enumerated() {
            writeImageToPasteboard(imgData)
            try? await Task.sleep(nanoseconds: 120_000_000)
            let pasteOk = await runOsascript("""
                tell application "System Events"
                    tell process "Ghostty"
                        keystroke "v" using {control down}
                    end tell
                end tell
                """)
            if !pasteOk {
                Self.logger.info("AppleScript paste failed, falling back to CGEvent")
                postCmdV()
            }
            if idx < images.count - 1 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        try? await Task.sleep(nanoseconds: 400_000_000)

        // Send accompanying text via clipboard (keystroke can't handle CJK)
        if !text.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            _ = await runOsascript("""
                tell application "System Events"
                    tell process "Ghostty"
                        keystroke "v" using {command down}
                    end tell
                end tell
                """)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await runOsascript("""
            tell application "System Events"
                tell process "Ghostty"
                    key code 36
                end tell
            end tell
            """)

        Self.logger.info("Pasted \(images.count) image(s) + text via Ghostty")
        return true
    }
}

// MARK: - cmuxPath hoist for nonisolated access

/// The nonisolated helpers above need to resolve the cmux CLI path. We delegate
/// to the shared `CmuxBinary` resolver so the relay finds cmux at the SAME
/// locations `LaunchService` does (Homebrew, ~/Applications, a running app's
/// bundle, …) — not just the old hardcoded `/Applications/cmux.app` path that
/// silently broke the relay for every non-standard install (issues #49, #62).
/// Returns nil when cmux isn't installed anywhere.
extension TerminalWriter {
    nonisolated fileprivate var cmuxPath: String? { CmuxBinary.resolvedPath() }
}
