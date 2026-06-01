//
//  TerminalJumper.swift
//  ClaudeIsland
//
//  Unified terminal jumping service.
//  Detects which terminal app hosts a Claude session and activates the correct window/tab.
//

import AppKit
import Foundation

actor TerminalJumper {
    static let shared = TerminalJumper()

    private init() {}

    /// Jump to the terminal hosting the given session.
    /// Tries strategies in order: tmux+Yabai → AppleScript → generic activate.
    func jump(to session: SessionState) async -> Bool {
        let cwd = session.cwd
        let pid = session.pid
        let terminalApp = session.terminalApp ?? ""
        DebugLogger.log("Jump", "termApp=\(terminalApp) cwd=\(cwd) sid=\(session.sessionId.prefix(8))")

        // 1. Tmux + Yabai (most precise for tmux sessions)
        if session.isInTmux {
            if let pid = pid {
                if await YabaiController.shared.focusWindow(forClaudePid: pid) {
                    return true
                }
            }
            if await YabaiController.shared.focusWindow(forWorkingDirectory: cwd) {
                return true
            }
        }

        // 2. AppleScript strategies for specific terminals
        let lower = terminalApp.lowercased()

        if lower.contains("iterm") {
            if await jumpViaiTerm2(cwd: cwd, pid: pid, tty: session.tty) { return true }
        }

        if lower.contains("terminal") && !lower.contains("wez") {
            if await jumpViaTerminalApp(cwd: cwd, pid: pid) { return true }
        }

        if lower.contains("cmux") {
            if await jumpViaCmux(cwd: cwd, sessionId: session.sessionId, tty: session.tty, surfaceId: session.cmuxSurfaceId) { return true }
        }

        if lower.contains("ghostty") {
            if await jumpViaGhostty(cwd: cwd) { return true }
        }

        if lower.contains("kitty") {
            if await jumpViaKitty(cwd: cwd) { return true }
        }

        if lower.contains("wezterm") {
            if await jumpViaWezTerm(cwd: cwd) { return true }
        }

        if lower.contains("warp") {
            if await activateByBundleId("warp") { return true }
        }

        if lower.contains("alacritty") {
            if await activateByBundleId("alacritty") { return true }
        }

        if lower.contains("hyper") {
            if await activateByBundleId("hyper") { return true }
        }

        // 3. If terminal app unknown OR all specific strategies failed,
        //    probe common terminals — but ONLY the ones that are actually running.
        //    Previously this block ran `jumpViaCmux` unconditionally even when
        //    the user was on iTerm, which could dispatch an AppleEvent to a
        //    missing cmux and hang/fail silently.
        if isRunning(bundleId: "com.cmuxterm.app") {
            if await jumpViaCmux(cwd: cwd, sessionId: session.sessionId, tty: session.tty, surfaceId: session.cmuxSurfaceId) { return true }
        }
        if isRunning(bundleId: "com.mitchellh.ghostty") {
            if await jumpViaGhostty(cwd: cwd) { return true }
        }
        if isRunning(bundleId: "com.googlecode.iterm2") {
            if await jumpViaiTerm2(cwd: cwd, pid: pid, tty: session.tty) { return true }
        }
        if isRunning(bundleId: "com.apple.Terminal") {
            if await jumpViaTerminalApp(cwd: cwd, pid: pid) { return true }
        }

        // 4. Generic fallback: activate terminal app by bundle ID
        if !terminalApp.isEmpty {
            if await activateByBundleId(terminalApp) { return true }
        }

        // 5. Last resort: activate any running terminal
        for bundleId in ["com.cmuxterm.app", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.googlecode.iterm2", "com.apple.Terminal"] {
            if activateRunningApp(bundleId: bundleId) { return true }
        }
        return false
    }

    /// Cheap sync probe: is an app with this bundle id currently running?
    /// Used to avoid dispatching AppleEvents to missing targets (which can
    /// hang osascript or trigger spurious TCC prompts).
    private func isRunning(bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    // MARK: - iTerm2 (AppleScript — rich API)

    private func jumpViaiTerm2(cwd: String, pid: Int?, tty: String? = nil) async -> Bool {
        // Strategy 1: match by tty (most reliable — exact device match)
        // SessionStore strips "/dev/" prefix, but iTerm2 returns full path like "/dev/ttys000"
        if let tty = tty, !tty.isEmpty {
            let fullTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            let ttyScript = """
            tell application "System Events"
                if not (exists process "iTerm2") then return false
            end tell
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if tty of s is "\(fullTty)" then
                                    select t
                                    select s
                                    activate
                                    return true
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
            if await runAppleScript(ttyScript) { return true }
        }

        // Strategy 2: match by session name containing directory name
        let dirName = URL(fileURLWithPath: cwd).lastPathComponent

        // Strategy 1: Match by tty (most reliable — iTerm2 exposes tty per session)
        if let pid = pid {
            let ttyScript = """
            tell application "System Events"
                if not (exists process "iTerm2") then return false
            end tell
            set targetTTY to do shell script "ps -o tty= -p \(pid) 2>/dev/null || echo none"
            if targetTTY is "none" then return false
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if tty of s contains targetTTY then
                                    select t
                                    select s
                                    set index of w to 1
                                    activate
                                    return true
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
            if await runAppleScript(ttyScript) { return true }
        }

        // Strategy 2: Match by session name containing directory name
        let nameScript = """
        tell application "System Events"
            if not (exists process "iTerm2") then return false
        end tell
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            set sName to name of s
                            set sPath to path of s
                            if sName contains "\(dirName)" or sPath contains "\(dirName)" then
                                select t
                                select s
                                set index of w to 1
                                activate
                                return true
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            activate
            return true
        end tell
        """
        return await runAppleScript(nameScript)
    }

    // MARK: - Terminal.app (AppleScript)

    private func jumpViaTerminalApp(cwd: String, pid: Int?) async -> Bool {
        let dirName = URL(fileURLWithPath: cwd).lastPathComponent
        let script = """
        tell application "System Events"
            if not (exists process "Terminal") then return false
        end tell
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if custom title of t contains "\(dirName)" or history of t contains "\(dirName)" then
                            set selected tab of w to t
                            set frontmost of w to true
                            activate
                            return true
                        end if
                    end try
                end repeat
            end repeat
            activate
            return true
        end tell
        """
        return await runAppleScript(script)
    }

    // MARK: - cmux (native AppleScript — `focus terminal`)

    private func jumpViaCmux(cwd: String, sessionId: String? = nil, tty: String? = nil, surfaceId: String? = nil) async -> Bool {
        guard CmuxTreeParser.isAvailable else { return false }

        // Tier 1 (most robust): focus by the cmux surface ID the hook captured
        // (CMUX_SURFACE_ID → SessionState.cmuxSurfaceId). Immune to the cwd
        // drift — pane closed, `cd`'d away, symlink/trailing-slash mismatch —
        // that makes the working-directory match miss (issue #62). If the ID is
        // stale/unknown cmux just errors and we fall through to the cwd match.
        if let surfaceId, !surfaceId.isEmpty {
            DebugLogger.log("Jump", "cmux jump by surfaceId=\(surfaceId.prefix(8))…")
            if await CmuxTreeParser.jump(panelId: surfaceId) {
                return true
            }
        }

        // Tier 2: focus the terminal whose working directory matches (guarded).
        DebugLogger.log("Jump", "cmux jump: cwd=\(cwd)")
        if await CmuxTreeParser.jump(cwd: cwd) {
            return true
        }

        // Tier 3: just bring cmux to front.
        DebugLogger.log("Jump", "cmux focus failed, activating cmux app")
        await bringCmuxToFront()
        return true
    }

    // MARK: - Ghostty (AppleScript)

    private func jumpViaGhostty(cwd: String) async -> Bool {
        let script = """
        tell application "System Events"
            if not (exists process "Ghostty") then return false
        end tell
        tell application "Ghostty"
            set matches to every terminal whose working directory contains "\(cwd)"
            if (count of matches) > 0 then
                focus (item 1 of matches)
                return true
            end if
            activate
            return true
        end tell
        """
        return await runAppleScript(script)
    }

    // MARK: - Kitty (CLI remote control)

    private func jumpViaKitty(cwd: String) async -> Bool {
        let kittyPaths = ["/opt/homebrew/bin/kitty", "/usr/local/bin/kitty",
                          "/Applications/kitty.app/Contents/MacOS/kitty"]
        guard let kittyPath = kittyPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return await activateByBundleId("kitty")
        }
        do {
            _ = try await ProcessExecutor.shared.run(kittyPath, arguments: [
                "@", "focus-window", "--match", "cwd:\(cwd)"
            ])
            await activateApp("kitty")
            return true
        } catch {
            return await activateByBundleId("kitty")
        }
    }

    // MARK: - WezTerm (CLI)

    private func jumpViaWezTerm(cwd: String) async -> Bool {
        let wezPaths = ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
                        "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
        guard let wezPath = wezPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return await activateByBundleId("wezterm")
        }
        do {
            let output = try await ProcessExecutor.shared.run(wezPath, arguments: [
                "cli", "list", "--format", "json"
            ])
            if output.contains(cwd) {
                await activateApp("WezTerm")
                return true
            }
        } catch {}
        return await activateByBundleId("wezterm")
    }

    // MARK: - Generic Bundle ID Activation

    @discardableResult
    private func activateByBundleId(_ terminalApp: String) async -> Bool {
        let lower = terminalApp.lowercased()

        let bundleMap: [(match: String, bundleId: String)] = [
            ("iterm", "com.googlecode.iterm2"),
            ("terminal", "com.apple.Terminal"),
            ("ghostty", "com.mitchellh.ghostty"),
            ("alacritty", "io.alacritty"),
            ("kitty", "net.kovidgoyal.kitty"),
            ("warp", "dev.warp.Warp-Stable"),
            ("wezterm", "com.github.wez.wezterm"),
            ("hyper", "co.zeit.hyper"),
            ("cmux", "com.cmuxterm.app"),
        ]

        for (match, bundleId) in bundleMap {
            if lower.contains(match) {
                return activateRunningApp(bundleId: bundleId)
            }
        }
        return false
    }

    @discardableResult
    private func activateRunningApp(bundleId: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            return app.activate()
        }
        return false
    }

    @discardableResult
    private func activateApp(_ name: String) async -> Bool {
        let script = "tell application \"\(name)\" to activate"
        return await runAppleScript(script)
    }

    // MARK: - cmux Activation

    private func bringCmuxToFront() async {
        // Use AppleScript to ensure cmux is frontmost
        _ = await runAppleScript("tell application \"cmux\" to activate")
    }

    // MARK: - AppleScript Runner

    private func runAppleScript(_ source: String) async -> Bool {
        do {
            let result = try await ProcessExecutor.shared.run("/usr/bin/osascript", arguments: ["-e", source])
            return result.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch {
            return false
        }
    }
}
