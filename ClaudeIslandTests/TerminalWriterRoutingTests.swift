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

    func test_standardCmuxSubmissionAppendsReturnInline() {
        let plan = TerminalWriter.cmuxSubmissionPlan(
            text: "OK",
            terminalApp: "Ghostty",
            hasSurfaceTarget: true
        )

        XCTAssertEqual(plan, .appendReturn("OK\r"))
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
