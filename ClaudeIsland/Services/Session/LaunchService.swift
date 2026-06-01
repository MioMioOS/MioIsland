//
//  LaunchService.swift
//  ClaudeIsland
//
//  Spawns a new cmux workspace via subprocess. Triggered by a `session-launch`
//  socket event from a paired iPhone, or directly for testing.
//
//  Maps to: `cmux new-workspace --cwd <projectPath> --command "<command>"`
//

import Foundation
import os.log

@MainActor
final class LaunchService {
    static let shared = LaunchService()
    static let logger = Logger(subsystem: "com.codeisland", category: "LaunchService")

    private init() {}

    /// Look up a preset by ID and spawn it in the given project path.
    /// Returns true on successful process launch (does NOT wait for session readiness).
    @discardableResult
    func launch(presetId: String, projectPath: String) -> Bool {
        guard let preset = PresetStore.shared.preset(id: presetId) else {
            Self.logger.warning("launch: unknown presetId=\(presetId, privacy: .public)")
            return false
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else {
            Self.logger.warning("launch: invalid projectPath=\(projectPath, privacy: .public)")
            return false
        }

        guard let cmuxPath = findCmuxBinary() else {
            Self.logger.error("launch: cmux binary not found in any known path")
            return false
        }

        // cmux's native top-level command: `new-workspace --cwd <path> --command <cmd>`.
        // Passing the full command as a single --command arg keeps quoting simple.
        let args = ["new-workspace", "--cwd", projectPath, "--command", preset.command]

        Self.logger.info("Launching: \(cmuxPath, privacy: .public) \(args.joined(separator: " "), privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmuxPath)
        process.arguments = args
        // Inherit a useful PATH so cmux can find `claude` etc.
        // (Fully qualified — there's a local `ProcessInfo` struct in Shared/ProcessTreeBuilder.swift)
        var env = Foundation.ProcessInfo.processInfo.environment
        let homeBin = "\(NSHomeDirectory())/.local/bin"
        let extras = ["/opt/homebrew/bin", "/usr/local/bin", homeBin]
        let currentPath = env["PATH"] ?? ""
        let merged = (extras + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
        env["PATH"] = merged
        process.environment = env

        do {
            try process.run()
            // cmux new-session returns quickly after spawning the workspace,
            // we don't need to wait or capture output.
            return true
        } catch {
            Self.logger.error("launch: process.run failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Helpers

    private func findCmuxBinary() -> String? {
        // Delegates to the shared resolver so the launcher and the phone→terminal
        // relay (TerminalWriter) agree on where cmux lives. See CmuxBinary.
        CmuxBinary.resolvedPath()
    }

}
