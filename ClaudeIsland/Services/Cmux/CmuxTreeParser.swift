//
//  CmuxTreeParser.swift
//  ClaudeIsland
//
//  Provides cross-window cmux navigation using cmux's native AppleScript dictionary.
//  Commands used: `focus terminal`, `activate window`, `select tab`, `input text`.
//  No cmux socket or System Events needed — only Automation permission for cmux.
//
//  All AppleScript dispatch goes through ProcessExecutor (an actor) so the
//  MainActor never blocks while macOS shows the TCC permission prompt.
//  Calls that hit a first-time TCC denial (-1743 errAEEventNotPermitted) are
//  retried once after a short delay so the user can grant permission and have
//  the action succeed without re-clicking the button.
//

import AppKit
import Foundation

/// Reads cmux session state and provides cross-window jumping via AppleScript
struct CmuxTreeParser {

    /// Check if cmux is running
    static var isAvailable: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first != nil
    }

    // MARK: - Jump

    /// Focus the terminal whose working directory matches `cwd`.
    /// Brings the correct window to front, selects the workspace, and focuses
    /// the pane in one AppleScript call.
    @discardableResult
    static func jump(cwd: String) async -> Bool {
        // Normalize so a trailing slash / "." / ".." doesn't defeat the match
        // (cmux reports a canonical path; the session cwd may not be).
        let normalized = normalizedPath(cwd)
        // Guard with `count` instead of `first terminal whose …`: the old form
        // threw `-1719 Invalid index` whenever NO pane currently had that cwd
        // (pane closed, cd'd away, path mismatch) — that's exactly the failure
        // in issue #62. Returning a sentinel lets the caller fall back cleanly.
        let script = """
        tell application "cmux"
            set matches to (every terminal whose working directory is "\(escapeAS(normalized))")
            if (count of matches) is 0 then return "none"
            focus (item 1 of matches)
            return "ok"
        end tell
        """
        let result = (await runASAsync(script).output)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = (result == "ok")
        DebugLogger.log("Cmux", "focus terminal cwd=\"\(normalized)\" ok=\(ok) result=\(result ?? "nil")")
        return ok
    }

    /// Canonicalize a filesystem path for matching against cmux's reported
    /// `working directory` — strips trailing slashes and resolves `.`/`..`.
    /// (Symlinks are intentionally left unresolved: cmux reports the path the
    /// shell is actually in, which may itself be a symlink.)
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Focus a terminal by its UUID (from session JSON panel id).
    @discardableResult
    static func jump(panelId: String) async -> Bool {
        let script = """
        tell application "cmux"
            focus terminal id "\(escapeAS(panelId))"
        end tell
        """
        let ok = await runASAsync(script).isSuccess
        DebugLogger.log("Cmux", "focus terminal id=\"\(panelId.prefix(8))…\" ok=\(ok)")
        return ok
    }

    // MARK: - Send Text (for permission approval)

    /// Send text to a terminal identified by working directory.
    static func sendText(_ text: String, toCwd cwd: String) async -> Bool {
        let script = """
        tell application "cmux"
            set targetTerm to (first terminal whose working directory is "\(escapeAS(cwd))")
            input text "\(escapeAS(text))" to targetTerm
        end tell
        """
        return await runASAsync(script).isSuccess
    }

    // MARK: - Visibility

    /// Check if a session's terminal is currently the focused terminal in the front window.
    static func isSessionActive(cwd: String) async -> Bool {
        guard isAvailable else { return true }
        let script = """
        tell application "cmux"
            if not frontmost then return "no"
            set ft to focused terminal of (selected tab of front window)
            if working directory of ft is "\(escapeAS(cwd))" then return "yes"
            return "no"
        end tell
        """
        let result = (await runASAsync(script).output)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result == "yes"
    }

    // MARK: - AppleScript Helpers

    /// Outcome of an `osascript` call. We only ever care about success vs.
    /// failure plus the trimmed stdout, so a thin wrapper keeps callers simple.
    private struct ASResult {
        let isSuccess: Bool
        let output: String?
    }

    /// Run an AppleScript via the shared `ProcessExecutor` actor so the
    /// MainActor never blocks. Detects the first-time TCC denial
    /// (errAEEventNotPermitted, -1743) and retries once after a short delay
    /// so that clicking "允许" in the system prompt produces a successful jump
    /// without the user needing to re-click the button.
    private static func runASAsync(_ source: String) async -> ASResult {
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/osascript",
            arguments: ["-e", source]
        )
        switch result {
        case .success(let pr):
            return ASResult(isSuccess: true, output: pr.output)
        case .failure(let err):
            if isTCCFirstCallDenial(err) {
                DebugLogger.log("Cmux", "AS first-call TCC denial (-1743) — retrying after 1.5s")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let retry = await ProcessExecutor.shared.runWithResult(
                    "/usr/bin/osascript",
                    arguments: ["-e", source]
                )
                switch retry {
                case .success(let pr):
                    return ASResult(isSuccess: true, output: pr.output)
                case .failure(let retryErr):
                    DebugLogger.log("Cmux", "AS retry also failed: \(retryErr.localizedDescription.prefix(200))")
                    return ASResult(isSuccess: false, output: nil)
                }
            }
            DebugLogger.log("Cmux", "AS error: \(err.localizedDescription.prefix(300))")
            return ASResult(isSuccess: false, output: nil)
        }
    }

    /// Detect the macOS "first call after grant fails with -1743" pattern so
    /// we know to retry once. Any other failure is treated as a real error.
    private static func isTCCFirstCallDenial(_ err: ProcessExecutorError) -> Bool {
        guard case let .executionFailed(_, _, stderr) = err, let stderr else { return false }
        return stderr.contains("-1743") || stderr.contains("errAEEventNotPermitted")
    }

    private static func escapeAS(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
