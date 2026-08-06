//
//  HookHealthCheck.swift
//  ClaudeIsland
//
//  Diagnostics for Claude and Codex hook installations.
//

import Foundation

struct HookHealthReport: Equatable {
    enum Severity: Equatable {
        case error
        case info
    }

    enum Issue: Equatable, CustomStringConvertible {
        /// The hook script is not found at the expected path.
        case scriptMissing(path: String)
        /// The hook script exists but is not executable.
        case scriptNotExecutable(path: String)
        /// The config file contains invalid JSON.
        case configMalformedJSON(path: String)
        /// A command in the config references a script path that no longer exists.
        case staleCommandPath(recorded: String, configPath: String)
        /// Other (non-CodeIsland) hooks detected alongside ours — informational.
        case otherHooksDetected(names: [String])
        /// The Codex installation manifest is missing even though hooks appear installed.
        case manifestMissing(expectedPath: String)

        var description: String {
            switch self {
            case .scriptMissing(let path):
                "Hook script not found: \(path)"
            case .scriptNotExecutable(let path):
                "Hook script exists but is not executable: \(path)"
            case .configMalformedJSON(let path):
                "Config file is not valid JSON: \(path)"
            case .staleCommandPath(let recorded, let configPath):
                "Command in \(configPath) points to missing script: \(recorded)"
            case .otherHooksDetected(let names):
                "Other hooks coexist: \(names.joined(separator: ", "))"
            case .manifestMissing(let expectedPath):
                "Installation manifest missing: \(expectedPath)"
            }
        }

        var severity: Severity {
            switch self {
            case .otherHooksDetected:
                return .info
            default:
                return .error
            }
        }

        /// True when re-running install would likely fix this.
        var isAutoRepairable: Bool {
            switch self {
            case .staleCommandPath, .scriptNotExecutable, .manifestMissing:
                return true
            default:
                return false
            }
        }
    }

    var agent: String
    var issues: [Issue]
    var scriptPath: String?
    var configPath: String?

    /// True when there are no error-severity issues.
    var isHealthy: Bool { errors.isEmpty }

    var errors: [Issue] { issues.filter { $0.severity == .error } }
    var notices: [Issue] { issues.filter { $0.severity == .info } }
    var repairableIssues: [Issue] { issues.filter(\.isAutoRepairable) }
}

enum HookHealthCheck {

    // MARK: - Claude

    /// Check Claude Code hook health.
    static func checkClaude(
        claudeDirectory: URL = ConfigPaths.claudeDir,
        fileManager: FileManager = .default
    ) -> HookHealthReport {
        var issues: [HookHealthReport.Issue] = []

        let scriptURL = claudeDirectory
            .appendingPathComponent("hooks")
            .appendingPathComponent("codeisland-state.py")
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let scriptPath = scriptURL.path
        let settingsPath = settingsURL.path

        // 1. Script exists and is executable
        if fileManager.fileExists(atPath: scriptPath) {
            if !fileManager.isExecutableFile(atPath: scriptPath) {
                issues.append(.scriptNotExecutable(path: scriptPath))
            }
        } else {
            issues.append(.scriptMissing(path: scriptPath))
        }

        // 2. Config JSON validity, stale paths, other hooks
        if fileManager.fileExists(atPath: settingsPath),
           let data = try? Data(contentsOf: settingsURL) {
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                issues.append(.configMalformedJSON(path: settingsPath))
            } else {
                for path in findStaleScriptPaths(in: data, fileManager: fileManager) {
                    issues.append(.staleCommandPath(recorded: path, configPath: settingsPath))
                }
                let others = findOtherHookNames(in: data)
                if !others.isEmpty {
                    issues.append(.otherHooksDetected(names: others))
                }
            }
        }

        return HookHealthReport(
            agent: "claude",
            issues: issues,
            scriptPath: scriptPath,
            configPath: settingsPath
        )
    }

    // MARK: - Codex

    /// Check Codex hook health.
    static func checkCodex(
        codexDirectory: URL = ConfigPaths.codexDir,
        fileManager: FileManager = .default
    ) -> HookHealthReport {
        var issues: [HookHealthReport.Issue] = []

        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let manifestURL = codexDirectory.appendingPathComponent(CodexHookInstallerManifest.fileName)
        let legacyManifestURL = codexDirectory.appendingPathComponent(CodexHookInstallerManifest.legacyFileName)
        let hooksPath = hooksURL.path

        // 1. Script existence via manifest
        let manifest = loadCodexManifest(at: manifestURL)
            ?? loadCodexManifest(at: legacyManifestURL)
        let scriptPath: String? = manifest.flatMap { extractScriptPath(from: $0.hookCommand) }

        if let path = scriptPath {
            let expanded = (path as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                if !fileManager.isExecutableFile(atPath: expanded) {
                    issues.append(.scriptNotExecutable(path: path))
                }
            } else {
                issues.append(.scriptMissing(path: path))
            }
        }

        // 2. Config JSON validity, stale paths, other hooks
        if fileManager.fileExists(atPath: hooksPath),
           let data = try? Data(contentsOf: hooksURL) {
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                issues.append(.configMalformedJSON(path: hooksPath))
            } else {
                for path in findStaleScriptPaths(in: data, fileManager: fileManager) {
                    issues.append(.staleCommandPath(recorded: path, configPath: hooksPath))
                }
                let others = findOtherHookNames(in: data)
                if !others.isEmpty {
                    issues.append(.otherHooksDetected(names: others))
                }
            }
        }

        // 3. Manifest present when hooks are installed
        if fileManager.fileExists(atPath: hooksPath),
           hasCodeIslandHooks(in: hooksURL, fileManager: fileManager),
           !fileManager.fileExists(atPath: manifestURL.path),
           !fileManager.fileExists(atPath: legacyManifestURL.path) {
            issues.append(.manifestMissing(expectedPath: manifestURL.path))
        }

        return HookHealthReport(
            agent: "codex",
            issues: issues,
            scriptPath: scriptPath,
            configPath: hooksPath
        )
    }

    // MARK: - Private helpers

    /// Returns script paths from hook commands that reference codeisland-state.py
    /// but point to files that no longer exist.
    private static func findStaleScriptPaths(in data: Data, fileManager: FileManager) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }

        var stale: [String] = []
        var seen: Set<String> = []

        for (_, eventValue) in hooks {
            let groups = eventValue as? [[String: Any]] ?? []
            for group in groups {
                let entries = group["hooks"] as? [[String: Any]] ?? []
                for hook in entries {
                    guard let command = hook["command"] as? String,
                          command.contains("codeisland-state.py"),
                          let path = extractScriptPath(from: command),
                          !seen.contains(path) else { continue }
                    seen.insert(path)
                    let expanded = (path as NSString).expandingTildeInPath
                    if !fileManager.fileExists(atPath: expanded) {
                        stale.append(path)
                    }
                }
            }
        }

        return stale
    }

    /// Returns display names for non-CodeIsland hooks found in a config file.
    private static func findOtherHookNames(in data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }

        var names: Set<String> = []
        for (_, eventValue) in hooks {
            let groups = eventValue as? [[String: Any]] ?? []
            for group in groups {
                let entries = group["hooks"] as? [[String: Any]] ?? []
                for hook in entries {
                    guard let command = hook["command"] as? String,
                          !command.contains("codeisland-state.py") else { continue }
                    let name = commandBaseName(from: command)
                    if !name.isEmpty { names.insert(name) }
                }
            }
        }

        return names.sorted()
    }

    /// Returns true if hooks.json contains any CodeIsland-managed hook.
    private static func hasCodeIslandHooks(in url: URL, fileManager: FileManager) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }

        for (_, eventValue) in hooks {
            let groups = eventValue as? [[String: Any]] ?? []
            for group in groups {
                let entries = group["hooks"] as? [[String: Any]] ?? []
                if entries.contains(where: { ($0["command"] as? String)?.contains("codeisland-state.py") == true }) {
                    return true
                }
            }
        }
        return false
    }

    /// Extracts the script path from a hook command string.
    /// Format: "python3 /path/to/script.py" or "python3 ~/.claude/hooks/codeisland-state.py"
    private static func extractScriptPath(from command: String) -> String? {
        command
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .filter { !$0.isEmpty }
            .last
    }

    /// Returns the basename of the first word in a command string.
    private static func commandBaseName(from command: String) -> String {
        let first = command
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .first ?? ""
        return (first as NSString).lastPathComponent
    }

    private static func loadCodexManifest(at url: URL) -> CodexHookInstallerManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CodexHookInstallerManifest.self, from: data)
    }
}
