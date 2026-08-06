//
//  CodexHookInstaller.swift
//  ClaudeIsland
//
//  Installs/uninstalls Code Island hooks into Codex's hooks.json and config.toml.
//  Mirrors HookInstaller's interface: installIfNeeded(), isInstalled(), uninstall().
//

import Foundation

struct CodexHookInstallerManifest: Equatable, Codable, Sendable {
    static let fileName = "code-island-codex-install.json"
    static let legacyFileName = "open-island-codex-install.json"

    var hookCommand: String
    var enabledCodexHooksFeature: Bool
    var installedAt: Date

    init(hookCommand: String, enabledCodexHooksFeature: Bool, installedAt: Date = .now) {
        self.hookCommand = hookCommand
        self.enabledCodexHooksFeature = enabledCodexHooksFeature
        self.installedAt = installedAt
    }
}

struct CodexFeatureMutation: Equatable, Sendable {
    var contents: String
    var changed: Bool
    var featureEnabledByInstaller: Bool
}

struct CodexHookFileMutation: Equatable, Sendable {
    var contents: Data?
    var changed: Bool
    var hasRemainingHooks: Bool
}

enum CodexHookInstallerError: Error, LocalizedError {
    case invalidHooksJSON

    var errorDescription: String? {
        switch self {
        case .invalidHooksJSON:
            "The existing Codex hooks file is not valid JSON."
        }
    }
}

enum CodexHookInstaller {
    static let managedStatusMessage = "Managed by Code Island"
    static let legacyManagedStatusMessage = "Managed by Open Island"
    static let managedTimeout = 45

    private static let eventSpecs: [(name: String, matcher: String?)] = [
        ("SessionStart", "startup|resume"),
        ("UserPromptSubmit", nil),
        ("Stop", nil),
    ]

    // MARK: - Top-Level Lifecycle (mirrors HookInstaller)

    /// Install Codex hooks on app launch.
    static func installIfNeeded() {
        let codexDir = ConfigPaths.codexDir
        try? FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let scriptPath = ConfigPaths.hookScript.path
        let command = hookCommand(for: scriptPath)

        let configURL = ConfigPaths.codexConfig
        let hooksURL = ConfigPaths.codexHooks
        let manifestURL = codexDir.appendingPathComponent(CodexHookInstallerManifest.fileName)
        let legacyManifestURL = codexDir.appendingPathComponent(CodexHookInstallerManifest.legacyFileName)

        let existingConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let existingHooks = try? Data(contentsOf: hooksURL)

        let featureMutation = enableCodexHooksFeature(in: existingConfig)
        guard let hooksMutation = try? installHooksJSON(existingData: existingHooks, hookCommand: command) else { return }

        if featureMutation.changed {
            try? featureMutation.contents.write(to: configURL, atomically: true, encoding: .utf8)
        }
        if let hooksData = hooksMutation.contents {
            try? hooksData.write(to: hooksURL, options: .atomic)
        }

        let manifest = CodexHookInstallerManifest(
            hookCommand: command,
            enabledCodexHooksFeature: featureMutation.featureEnabledByInstaller
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        if FileManager.default.fileExists(atPath: legacyManifestURL.path) {
            try? FileManager.default.removeItem(at: legacyManifestURL)
        }
    }

    /// Check if Codex hooks are currently installed.
    static func isInstalled() -> Bool {
        let hooksURL = ConfigPaths.codexHooks
        guard let data = try? Data(contentsOf: hooksURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooksObj = json["hooks"] as? [String: Any] else { return false }

        for (_, value) in hooksObj {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let hooks = group["hooks"] as? [[String: Any]] {
                    for hook in hooks {
                        if let cmd = hook["command"] as? String, cmd.contains("codeisland-state.py") {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall Codex hooks and optionally revert the feature flag.
    static func uninstall() {
        let codexDir = ConfigPaths.codexDir
        let configURL = ConfigPaths.codexConfig
        let hooksURL = ConfigPaths.codexHooks
        let primaryManifestURL = codexDir.appendingPathComponent(CodexHookInstallerManifest.fileName)
        let legacyManifestURL = codexDir.appendingPathComponent(CodexHookInstallerManifest.legacyFileName)
        let manifestURL = resolvedManifestURL(in: codexDir)

        let manifest = loadManifest(at: manifestURL)
        let existingHooks = try? Data(contentsOf: hooksURL)
        guard let hooksMutation = try? uninstallHooksJSON(
            existingData: existingHooks,
            managedCommand: manifest?.hookCommand
        ) else { return }

        if let hooksData = hooksMutation.contents {
            try? hooksData.write(to: hooksURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: hooksURL)
        }

        if let manifest, manifest.enabledCodexHooksFeature, !hooksMutation.hasRemainingHooks {
            let existingConfig = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let featureMutation = disableCodexHooksFeatureIfManaged(in: existingConfig)
            if featureMutation.changed {
                try? featureMutation.contents.write(to: configURL, atomically: true, encoding: .utf8)
            }
        }

        for candidate in [primaryManifestURL, legacyManifestURL]
            where FileManager.default.fileExists(atPath: candidate.path) {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    // MARK: - Pure Logic (used by HookHealthCheck and internally)

    static func hookCommand(for scriptPath: String) -> String {
        shellQuote(scriptPath)
    }

    static func installHooksJSON(existingData: Data?, hookCommand: String) throws -> CodexHookFileMutation {
        var rootObject = try loadRootObject(from: existingData)
        let existingHooksObject = rootObject["hooks"] as? [String: Any] ?? [:]
        var hooksObject: [String: Any] = [:]

        for (eventName, value) in existingHooksObject {
            let existingGroups = value as? [Any] ?? []
            let cleanedGroups = sanitizeForInstall(groups: existingGroups, replacingCommand: hookCommand)
            if !cleanedGroups.isEmpty {
                hooksObject[eventName] = cleanedGroups
            }
        }

        for spec in eventSpecs {
            let existingGroups = hooksObject[spec.name] as? [Any] ?? []
            let cleanedGroups = sanitizeForInstall(groups: existingGroups, replacingCommand: hookCommand)
            hooksObject[spec.name] = cleanedGroups + [managedGroup(matcher: spec.matcher, hookCommand: hookCommand)]
        }

        rootObject["hooks"] = hooksObject
        let data = try serialize(rootObject)
        return CodexHookFileMutation(contents: data, changed: data != existingData, hasRemainingHooks: true)
    }

    static func uninstallHooksJSON(existingData: Data?, managedCommand: String?) throws -> CodexHookFileMutation {
        guard let existingData else {
            return CodexHookFileMutation(contents: nil, changed: false, hasRemainingHooks: false)
        }

        var rootObject = try loadRootObject(from: existingData)
        var hooksObject = rootObject["hooks"] as? [String: Any] ?? [:]
        var mutated = false

        for spec in eventSpecs {
            let existingGroups = hooksObject[spec.name] as? [Any] ?? []
            let cleanedGroups = sanitize(groups: existingGroups, managedCommand: managedCommand)

            if cleanedGroups.count != existingGroups.count || containsManagedHook(in: existingGroups, managedCommand: managedCommand) {
                mutated = true
            }

            if cleanedGroups.isEmpty {
                hooksObject.removeValue(forKey: spec.name)
            } else {
                hooksObject[spec.name] = cleanedGroups
            }
        }

        if hooksObject.isEmpty {
            return CodexHookFileMutation(contents: nil, changed: mutated, hasRemainingHooks: false)
        }

        rootObject["hooks"] = hooksObject
        let data = try serialize(rootObject)
        return CodexHookFileMutation(contents: data, changed: mutated || data != existingData, hasRemainingHooks: true)
    }

    static func enableCodexHooksFeature(in contents: String) -> CodexFeatureMutation {
        var lines = contents.components(separatedBy: "\n")

        if let codexHookIndex = lineIndex(ofKey: "codex_hooks", inSection: "features", lines: lines) {
            let trimmed = lines[codexHookIndex].trimmingCharacters(in: .whitespaces)
            if trimmed == "codex_hooks = true" {
                return CodexFeatureMutation(contents: contents, changed: false, featureEnabledByInstaller: false)
            }
            lines[codexHookIndex] = "codex_hooks = true"
            return CodexFeatureMutation(
                contents: lines.joined(separator: "\n"),
                changed: true,
                featureEnabledByInstaller: true
            )
        }

        if let featuresRange = sectionRange(named: "features", lines: lines) {
            lines.insert("codex_hooks = true", at: featuresRange.upperBound)
            return CodexFeatureMutation(
                contents: lines.joined(separator: "\n"),
                changed: true,
                featureEnabledByInstaller: true
            )
        }

        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append("[features]")
        lines.append("codex_hooks = true")

        return CodexFeatureMutation(
            contents: lines.joined(separator: "\n"),
            changed: true,
            featureEnabledByInstaller: true
        )
    }

    static func disableCodexHooksFeatureIfManaged(in contents: String) -> CodexFeatureMutation {
        var lines = contents.components(separatedBy: "\n")
        guard let featuresRange = sectionRange(named: "features", lines: lines),
              let codexHookIndex = lineIndex(ofKey: "codex_hooks", inSection: "features", lines: lines) else {
            return CodexFeatureMutation(contents: contents, changed: false, featureEnabledByInstaller: false)
        }

        lines.remove(at: codexHookIndex)

        let updatedRange = sectionRange(named: "features", lines: lines) ?? featuresRange
        let remainingFeatureLines = lines[updatedRange.lowerBound + 1 ..< updatedRange.upperBound]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        if remainingFeatureLines.isEmpty, let featuresHeaderIndex = lines.firstIndex(of: "[features]") {
            lines.remove(at: featuresHeaderIndex)
            if featuresHeaderIndex < lines.count, lines[featuresHeaderIndex].isEmpty {
                lines.remove(at: featuresHeaderIndex)
            }
        }

        return CodexFeatureMutation(contents: lines.joined(separator: "\n"), changed: true, featureEnabledByInstaller: false)
    }

    // MARK: - Private Helpers

    private static func loadManifest(at url: URL) -> CodexHookInstallerManifest? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexHookInstallerManifest.self, from: data)
    }

    private static func resolvedManifestURL(in directory: URL) -> URL {
        let primaryURL = directory.appendingPathComponent(CodexHookInstallerManifest.fileName)
        if FileManager.default.fileExists(atPath: primaryURL.path) { return primaryURL }
        let legacyURL = directory.appendingPathComponent(CodexHookInstallerManifest.legacyFileName)
        return FileManager.default.fileExists(atPath: legacyURL.path) ? legacyURL : primaryURL
    }

    private static func loadRootObject(from data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let rootObject = object as? [String: Any] else {
            throw CodexHookInstallerError.invalidHooksJSON
        }
        return rootObject
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func sanitize(groups: [Any], managedCommand: String?) -> [[String: Any]] {
        groups.compactMap { item in
            guard var group = item as? [String: Any] else { return nil }
            let existingHooks = group["hooks"] as? [Any] ?? []
            let filteredHooks = existingHooks.compactMap { hook -> [String: Any]? in
                guard let hook = hook as? [String: Any] else { return nil }
                return isManagedHook(hook, managedCommand: managedCommand) ? nil : hook
            }
            guard !filteredHooks.isEmpty else { return nil }
            group["hooks"] = filteredHooks
            return group
        }
    }

    private static func sanitizeForInstall(groups: [Any], replacingCommand: String) -> [[String: Any]] {
        groups.compactMap { item in
            guard var group = item as? [String: Any] else { return nil }
            let existingHooks = group["hooks"] as? [Any] ?? []
            let filteredHooks = existingHooks.compactMap { hook -> [String: Any]? in
                guard let hook = hook as? [String: Any] else { return nil }
                return isManagedHookForInstall(hook, replacingCommand: replacingCommand) ? nil : hook
            }
            guard !filteredHooks.isEmpty else { return nil }
            group["hooks"] = filteredHooks
            return group
        }
    }

    private static func containsManagedHook(in groups: [Any], managedCommand: String?) -> Bool {
        groups.contains { item in
            guard let group = item as? [String: Any],
                  let hooks = group["hooks"] as? [Any] else { return false }
            return hooks.contains { hook in
                guard let hook = hook as? [String: Any] else { return false }
                return isManagedHook(hook, managedCommand: managedCommand)
            }
        }
    }

    private static func managedGroup(matcher: String?, hookCommand: String) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": hookCommand,
                "timeout": managedTimeout,
            ] as [String: Any]]
        ]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private static func isManagedHook(_ hook: [String: Any], managedCommand: String?) -> Bool {
        if let statusMessage = hook["statusMessage"] as? String,
           statusMessage == managedStatusMessage || statusMessage == legacyManagedStatusMessage {
            return true
        }
        guard let managedCommand else { return false }
        return hook["command"] as? String == managedCommand
    }

    private static func isManagedHookForInstall(_ hook: [String: Any], replacingCommand: String) -> Bool {
        if isManagedHook(hook, managedCommand: replacingCommand) { return true }
        guard let command = hook["command"] as? String else { return false }
        return isLegacyIslandHookCommand(command)
    }

    private static func isLegacyIslandHookCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
        return normalized.contains("openislandhooks")
            || normalized.contains("vibeislandhooks")
            || normalized.contains("open-island-bridge")
            || normalized.contains("vibe-island-bridge")
    }

    private static func sectionRange(named section: String, lines: [String]) -> Range<Int>? {
        guard let headerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[\(section)]"
        }) else { return nil }

        var endIndex = lines.count
        for index in (headerIndex + 1) ..< lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                endIndex = index
                break
            }
        }
        return headerIndex ..< endIndex
    }

    private static func lineIndex(ofKey key: String, inSection section: String, lines: [String]) -> Int? {
        guard let range = sectionRange(named: section, lines: lines) else { return nil }
        for index in (range.lowerBound + 1) ..< range.upperBound {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) =") { return index }
        }
        return nil
    }

    private static func shellQuote(_ string: String) -> String {
        guard !string.isEmpty else { return "''" }
        let needsQuoting = string.contains(where: { " \t\n\"'\\$`!".contains($0) })
        guard needsQuoting else { return string }
        return "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
