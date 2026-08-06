//
//  HookInstaller.swift
//  ClaudeIsland
//
//  Auto-installs Claude Code hooks on app launch
//

import Foundation

struct HookInstaller {

    /// True when the user explicitly switched hooks off (Settings toggle or
    /// diagnostics "uninstall"). Launch-time install and the auto-heal
    /// watcher (ClaudeSettingsWatcher) both respect this so we never fight
    /// an intentional opt-out.
    static var userDisabled: Bool {
        get { UserDefaults.standard.bool(forKey: "hookInstallUserDisabled") }
        set { UserDefaults.standard.set(newValue, forKey: "hookInstallUserDisabled") }
    }

    /// Install hook script and update settings.json on app launch
    static func installIfNeeded() {
        cleanupLegacyHooks()

        let hooksDir = ConfigPaths.claudeHooksDir
        let pythonScript = ConfigPaths.hookScript
        let settings = ConfigPaths.claudeSettings

        try? FileManager.default.createDirectory(
            at: hooksDir,
            withIntermediateDirectories: true
        )

        if let bundled = Bundle.main.url(forResource: "codeisland-state", withExtension: "py") {
            try? FileManager.default.removeItem(at: pythonScript)
            try? FileManager.default.copyItem(at: bundled, to: pythonScript)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: pythonScript.path
            )
        }

        updateSettings(at: settings)
    }

    private static func updateSettings(at settingsURL: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        let python = detectPython()
        let command = "\(python) \(ConfigPaths.hookScript.path)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let hookEntryWithTimeout: [[String: Any]] = [["type": "command", "command": command, "timeout": 86400]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withMatcherAndTimeout: [[String: Any]] = [["matcher": "*", "hooks": hookEntryWithTimeout]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]
        let preCompactConfig: [[String: Any]] = [
            ["matcher": "auto", "hooks": hookEntry],
            ["matcher": "manual", "hooks": hookEntry]
        ]

        var hooks = json["hooks"] as? [String: Any] ?? [:]

        let hookEvents: [(String, [[String: Any]])] = [
            ("UserPromptSubmit", withoutMatcher),
            ("PreToolUse", withMatcher),
            ("PostToolUse", withMatcher),
            ("PermissionRequest", withMatcherAndTimeout),
            ("Notification", withMatcher),
            ("Stop", withoutMatcher),
            ("SubagentStop", withoutMatcher),
            ("SessionStart", withoutMatcher),
            ("SessionEnd", withoutMatcher),
            ("PreCompact", preCompactConfig),
        ]

        for (event, config) in hookEvents {
            if var existingEvent = hooks[event] as? [[String: Any]] {
                let hasOurHook = existingEvent.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains("codeisland-state.py")
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existingEvent.append(contentsOf: config)
                    hooks[event] = existingEvent
                }
            } else {
                hooks[event] = config
            }
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settingsURL)
        }
    }

    /// Check if hooks are currently installed
    static func isInstalled() -> Bool {
        let settings = ConfigPaths.claudeSettings

        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("codeisland-state.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall hooks from settings.json and remove script
    static func uninstall() {
        let hooksDir = ConfigPaths.claudeHooksDir
        let pythonScript = ConfigPaths.hookScript
        let settings = ConfigPaths.claudeSettings

        try? FileManager.default.removeItem(at: pythonScript)

        guard let data = try? Data(contentsOf: settings),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { hook in
                            let cmd = hook["command"] as? String ?? ""
                            return cmd.contains("codeisland-state.py")
                        }
                    }
                    return false
                }

                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: settings)
        }
    }

    /// Script basenames left behind by older app versions (Claude Island,
    /// Code Island) that should no longer be referenced in settings.json.
    static let legacyHookScripts = ["claude-island-state.py"]

    /// Strip hook entries from older app versions and delete their leftover
    /// scripts. Idempotent — safe to run every launch.
    static func cleanupLegacyHooks() {
        let hooksDir = ConfigPaths.claudeHooksDir
        let settings = ConfigPaths.claudeSettings

        // 1. Delete legacy script files on disk (no-op if missing).
        for name in legacyHookScripts {
            let path = hooksDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: path)
        }

        // 2. Prune legacy entries from settings.json (pure function below).
        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let pruned = pruneLegacyHookEntries(from: json, legacyScripts: legacyHookScripts)
        guard pruned.changed else { return }

        guard let newData = try? JSONSerialization.data(
            withJSONObject: pruned.result,
            options: [.prettyPrinted, .sortedKeys]
        ), !newData.isEmpty,
              // Round-trip check: serialize → deserialize must succeed before we write.
              (try? JSONSerialization.jsonObject(with: newData)) != nil else {
            return
        }
        try? newData.write(to: settings, options: .atomic)
    }

    /// Pure function: given a decoded settings.json dict, return a copy with
    /// every hook group that references any legacy script removed. Empty
    /// hook events are dropped; if the entire `hooks` map ends up empty the
    /// `hooks` key itself is removed. `changed` is true iff at least one
    /// entry was pruned.
    ///
    /// Kept `internal` so future tests can `@testable import` this directly
    /// without touching the file system.
    static func pruneLegacyHookEntries(
        from json: [String: Any],
        legacyScripts: [String]
    ) -> (result: [String: Any], changed: Bool) {
        guard var hooks = json["hooks"] as? [String: Any] else {
            return (json, false)
        }

        func entryReferencesLegacy(_ entry: [String: Any]) -> Bool {
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return legacyScripts.contains { cmd.contains($0) }
            }
        }

        var changed = false
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll(where: entryReferencesLegacy)
            guard entries.count != before else { continue }
            changed = true
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        guard changed else { return (json, false) }

        var result = json
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return (result, true)
    }

    private static func detectPython() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "python3"
            }
        } catch {}

        return "python"
    }
}
