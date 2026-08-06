//
//  ConfigPaths.swift
//  ClaudeIsland
//
//  Centralises discovery of Claude Code and Codex configuration directories.
//  Respects the CLAUDE_CONFIG_DIR and CODEX_HOME environment variables so that
//  users who customise their config location are not forced back to the default.
//

import Foundation

enum ConfigPaths {
    /// Root directory for Claude Code configuration.
    /// Honours `CLAUDE_CONFIG_DIR` when set, otherwise falls back to `~/.claude`.
    static var claudeDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    /// Root directory for Codex configuration.
    /// Honours `CODEX_HOME` when set, otherwise falls back to `~/.codex`.
    static var codexDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    // MARK: - Convenience paths

    static var claudeHooksDir: URL { claudeDir.appendingPathComponent("hooks") }
    static var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }
    static var claudeProjectsDir: URL { claudeDir.appendingPathComponent("projects") }
    static var claudeSessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    static var claudeBuddyFile: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json") }
    static var claudeLogFile: URL { claudeDir.appendingPathComponent(".codeisland.log") }
    static var claudeSaltCache: URL { claudeDir.appendingPathComponent(".codeisland-salt") }
    static var claudeBonesCache: URL { claudeDir.appendingPathComponent(".codeisland-bones.json") }
    static var hookScript: URL { claudeHooksDir.appendingPathComponent("codeisland-state.py") }

    static var codexConfig: URL { codexDir.appendingPathComponent("config.toml") }
    static var codexHooks: URL { codexDir.appendingPathComponent("hooks.json") }

    /// Expand a path that may contain `~` using the current home directory.
    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
