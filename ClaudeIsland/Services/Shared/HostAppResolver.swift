//
//  HostAppResolver.swift
//  ClaudeIsland
//
//  Resolves the GUI application that (transitively) hosts a shell process.
//  Used when the process ancestry contains no registered terminal emulator —
//  e.g. Claude Code running inside Obsidian's terminal plugin, a JetBrains
//  IDE, or the Claude desktop app (issues #94 / #80).
//

import AppKit
import Foundation

enum HostAppResolver {
    struct HostApp: Sendable {
        let name: String
        let bundleId: String
    }

    /// Walk up the ppid chain from `pid` and return the first ancestor that
    /// is a regular (Dock-visible) GUI application. Helper/renderer
    /// processes (e.g. "Obsidian Helper (Renderer)") are skipped because
    /// they don't register as `.regular` with Launch Services — the walk
    /// continues until the owning app bundle is reached. Our own app is
    /// never returned.
    nonisolated static func hostApp(startingAt pid: Int, tree: [Int: ProcessInfo]) -> HostApp? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 20 {
            if let app = regularApp(forPid: current) {
                return app
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }

        return nil
    }

    private nonisolated static func regularApp(forPid pid: Int) -> HostApp? {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              app.activationPolicy == .regular,
              let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier else {
            return nil
        }
        return HostApp(name: app.localizedName ?? bundleId, bundleId: bundleId)
    }
}
