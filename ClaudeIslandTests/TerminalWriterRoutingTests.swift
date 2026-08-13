//
//  TerminalWriterRoutingTests.swift
//  ClaudeIslandTests
//

import XCTest
@testable import ClaudeIsland

final class TerminalWriterRoutingTests: XCTestCase {

    func test_cmuxWinsOverExplicitCodexTerminalHint() {
        let backend = TerminalWriter.preferredTerminalBackend(
            terminalApp: "Codex",
            hasCmuxTarget: true,
            detectedFallback: "ghostty"
        )

        XCTAssertEqual(backend, "cmux")
    }

    func test_explicitTerminalHintUsedWhenNoCmuxTarget() {
        let backend = TerminalWriter.preferredTerminalBackend(
            terminalApp: "Ghostty",
            hasCmuxTarget: false,
            detectedFallback: "terminal"
        )

        XCTAssertEqual(backend, "ghostty")
    }

    func test_detectedFallbackUsedWhenNoHintOrCmuxTarget() {
        let backend = TerminalWriter.preferredTerminalBackend(
            terminalApp: nil,
            hasCmuxTarget: false,
            detectedFallback: "iterm2"
        )

        XCTAssertEqual(backend, "iterm2")
    }

    func test_codexCmuxSubmissionUsesSeparateEnterKey() {
        let plan = TerminalWriter.cmuxSubmissionPlan(
            text: "OK",
            terminalApp: "Codex",
            hasSurfaceTarget: true
        )

        XCTAssertEqual(plan, .sendThenKey(text: "OK", key: "enter"))
    }

    /// Regression (phone→terminal): a Claude Code session running inside cmux
    /// reports `terminalApp == "cmux"`, so the old `== "codex"` check never
    /// fired and it fell back to the inline-`\r` path. Every agent TUI cmux
    /// drives needs a real Enter key event, so this is now the only path.
    func test_nonCodexCmuxSubmissionAlsoUsesSeparateEnterKey() {
        for app in ["cmux", "Ghostty", "iTerm2", nil] {
            let plan = TerminalWriter.cmuxSubmissionPlan(
                text: "OK",
                terminalApp: app,
                hasSurfaceTarget: true
            )

            XCTAssertEqual(plan, .sendThenKey(text: "OK", key: "enter"), "terminalApp: \(app ?? "nil")")
        }
    }

    /// Regression: the old path mapped every `\n` to `\r`, and `\r` is the Enter
    /// key — so one multi-line message was submitted as several separate
    /// messages. Newlines must survive as newlines.
    func test_multilineTextIsNotSplitIntoSeparateSubmissions() {
        let plan = TerminalWriter.cmuxSubmissionPlan(
            text: "line one\nline two\nline three",
            terminalApp: "cmux",
            hasSurfaceTarget: true
        )

        XCTAssertEqual(plan, .sendThenKey(text: "line one\nline two\nline three", key: "enter"))
    }

    /// Regression: past a payload-size threshold (~128 bytes on cmux 0.64.17)
    /// cmux writes text through a bulk path where a trailing `\r` is a literal
    /// newline, stranding the message in the composer unsent. A key event is
    /// size-independent.
    func test_longTextStillUsesSeparateEnterKey() {
        let long = String(repeating: "z", count: 4096)
        let plan = TerminalWriter.cmuxSubmissionPlan(
            text: long,
            terminalApp: "cmux",
            hasSurfaceTarget: true
        )

        XCTAssertEqual(plan, .sendThenKey(text: long, key: "enter"))
    }

    /// Regression: Codex's raw-mode TUI only submits on a real Enter KEY event;
    /// an inline `\r` is a literal newline in its composer and strands the text
    /// unsent. So Codex must use send-then-key even when no surface was
    /// resolved (`cmux send-key` defaults to the workspace's active surface).
    /// Previously this returned `.appendReturn("OK\r")` — that was the bug.
    func test_codexUsesSeparateEnterKeyEvenWithoutSurface() {
        let plan = TerminalWriter.cmuxSubmissionPlan(
            text: "OK",
            terminalApp: "Codex",
            hasSurfaceTarget: false
        )

        XCTAssertEqual(plan, .sendThenKey(text: "OK", key: "enter"))
    }

    /// terminalApp matching is case- and whitespace-insensitive, so a "codex"
    /// hint from any source still gets the key-event submit path.
    func test_codexMatchIsCaseAndWhitespaceInsensitive() {
        let plan = TerminalWriter.cmuxSubmissionPlan(
            text: "hi",
            terminalApp: "  codex ",
            hasSurfaceTarget: false
        )

        XCTAssertEqual(plan, .sendThenKey(text: "hi", key: "enter"))
    }
}
