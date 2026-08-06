//
//  CapabilityScanner.swift
//  ClaudeIsland
//
//  Scans the local filesystem for Claude Code capabilities — slash commands,
//  skills, MCP servers — so they can be surfaced in the phone's compose bar.
//
//  Data sources:
//    ~/.claude/commands/*.md                        user commands
//    ~/.claude/skills/*/SKILL.md                    user skills
//    ~/.claude/plugins/cache/*/*/*/commands/*.md    plugin commands
//    ~/.claude/plugins/cache/*/*/*/skills/*/SKILL.md  plugin skills
//    ~/.claude.json                                 MCP servers (global + per-project)
//    <cwd>/.claude/commands/*.md                    project-local commands
//    <cwd>/.claude/skills/*/SKILL.md                project-local skills
//

import Foundation
import os.log

struct CapabilityItem: Codable {
    let name: String
    let description: String
    let source: String      // "builtin" | "user" | "plugin:<name>" | "project"
}

struct CapabilitySnapshot: Codable {
    let builtinCommands: [CapabilityItem]
    let userCommands: [CapabilityItem]
    let pluginCommands: [CapabilityItem]
    let projectCommands: [CapabilityItem]
    let userSkills: [CapabilityItem]
    let pluginSkills: [CapabilityItem]
    let projectSkills: [CapabilityItem]
    let mcpServers: [CapabilityItem]
    let projectPath: String?
    let scannedAt: TimeInterval
}

enum CapabilityScanner {
    static let logger = Logger(subsystem: "com.codeisland", category: "CapabilityScanner")

    /// Scan everything. `projectPath` is optional — if provided, project-local
    /// commands/skills under that directory's `.claude/` are included.
    static func scan(projectPath: String? = nil) -> CapabilitySnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeDir = ConfigPaths.claudeDir

        let builtins = builtinSlashCommands()

        let userCmds = scanCommands(in: claudeDir.appendingPathComponent("commands"), source: "user")
        let userSkills = scanSkills(in: claudeDir.appendingPathComponent("skills"), source: "user")

        // Plugin cache layout: plugins/cache/<marketplace>/<plugin>/<version>/{commands,skills}
        var pluginCmds: [CapabilityItem] = []
        var pluginSkills: [CapabilityItem] = []
        let pluginCache = claudeDir.appendingPathComponent("plugins/cache")
        if let marketplaces = try? FileManager.default.contentsOfDirectory(atPath: pluginCache.path) {
            for marketplace in marketplaces {
                let marketplaceDir = pluginCache.appendingPathComponent(marketplace)
                guard let plugins = try? FileManager.default.contentsOfDirectory(atPath: marketplaceDir.path) else { continue }
                for plugin in plugins {
                    let pluginDir = marketplaceDir.appendingPathComponent(plugin)
                    guard let versions = try? FileManager.default.contentsOfDirectory(atPath: pluginDir.path) else { continue }
                    // Take the highest version string (usually only one)
                    guard let version = versions.sorted().last else { continue }
                    let versionDir = pluginDir.appendingPathComponent(version)
                    pluginCmds.append(contentsOf: scanCommands(
                        in: versionDir.appendingPathComponent("commands"),
                        source: "plugin:\(plugin)"
                    ))
                    pluginSkills.append(contentsOf: scanSkills(
                        in: versionDir.appendingPathComponent("skills"),
                        source: "plugin:\(plugin)"
                    ))
                }
            }
        }

        var projectCmds: [CapabilityItem] = []
        var projectSkills: [CapabilityItem] = []
        if let projectPath {
            let projectClaude = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude")
            projectCmds = scanCommands(in: projectClaude.appendingPathComponent("commands"), source: "project")
            projectSkills = scanSkills(in: projectClaude.appendingPathComponent("skills"), source: "project")
        }

        let mcp = scanMCPServers(home: home, projectPath: projectPath)

        let snapshot = CapabilitySnapshot(
            builtinCommands: builtins,
            userCommands: userCmds,
            pluginCommands: pluginCmds.sorted { $0.name < $1.name },
            projectCommands: projectCmds,
            userSkills: userSkills.sorted { $0.name < $1.name },
            pluginSkills: pluginSkills.sorted { $0.name < $1.name },
            projectSkills: projectSkills,
            mcpServers: mcp,
            projectPath: projectPath,
            scannedAt: Date().timeIntervalSince1970
        )

        logger.info("Scanned: builtin=\(builtins.count) userCmd=\(userCmds.count) pluginCmd=\(pluginCmds.count) userSkill=\(userSkills.count) pluginSkill=\(pluginSkills.count) mcp=\(mcp.count)")
        return snapshot
    }

    // MARK: - Slash Commands

    /// Claude Code's built-in slash commands. Hardcoded — they're not in any file.
    private static func builtinSlashCommands() -> [CapabilityItem] {
        [
            ("/help", "Show help and available commands"),
            ("/model", "Switch the Claude model for this session"),
            ("/cost", "Show current session cost"),
            ("/usage", "Show current token usage"),
            ("/clear", "Clear the conversation context"),
            ("/compact", "Compact the conversation history"),
            ("/init", "Initialize CLAUDE.md for the current project"),
            ("/config", "Show or edit configuration"),
            ("/release-notes", "Show recent Claude Code release notes"),
            ("/exit", "Exit Claude Code"),
            ("/bug", "Report a bug"),
            ("/fast", "Toggle fast output mode"),
        ].map { CapabilityItem(name: $0.0, description: $0.1, source: "builtin") }
    }

    private static func scanCommands(in dir: URL, source: String) -> [CapabilityItem] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [CapabilityItem] = []
        for url in entries where url.pathExtension == "md" {
            let baseName = url.deletingPathExtension().lastPathComponent
            let description = readFrontmatterDescription(url: url) ?? ""
            out.append(CapabilityItem(name: "/\(baseName)", description: description, source: source))
        }
        return out
    }

    // MARK: - Skills

    private static func scanSkills(in dir: URL, source: String) -> [CapabilityItem] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [CapabilityItem] = []
        for url in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillFile = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { continue }
            let name = readFrontmatterName(url: skillFile) ?? url.lastPathComponent
            let description = readFrontmatterDescription(url: skillFile) ?? ""
            out.append(CapabilityItem(name: name, description: description, source: source))
        }
        return out
    }

    // MARK: - MCP Servers

    private static func scanMCPServers(home: URL, projectPath: String?) -> [CapabilityItem] {
        let configFile = ConfigPaths.claudeBuddyFile
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var servers: [CapabilityItem] = []
        var seen = Set<String>()

        // Global user-level mcpServers
        if let global = json["mcpServers"] as? [String: Any] {
            for name in global.keys.sorted() where !seen.contains(name) {
                seen.insert(name)
                servers.append(CapabilityItem(name: name, description: "MCP server (global)", source: "mcp"))
            }
        }

        // Per-project mcpServers under projects.<path>.mcpServers
        if let projectPath,
           let projects = json["projects"] as? [String: Any],
           let projectEntry = projects[projectPath] as? [String: Any],
           let projectMcp = projectEntry["mcpServers"] as? [String: Any] {
            for name in projectMcp.keys.sorted() where !seen.contains(name) {
                seen.insert(name)
                servers.append(CapabilityItem(name: name, description: "MCP server (project)", source: "mcp:project"))
            }
        }

        return servers
    }

    // MARK: - Frontmatter Parsing

    /// Read the `name:` field out of a YAML frontmatter block at the top of a .md file.
    private static func readFrontmatterName(url: URL) -> String? {
        return readFrontmatterField(url: url, field: "name")
    }

    /// Read the `description:` field out of a YAML frontmatter block.
    private static func readFrontmatterDescription(url: URL) -> String? {
        return readFrontmatterField(url: url, field: "description")
    }

    private static func readFrontmatterField(url: URL, field: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read first 4 KB — plenty for frontmatter
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Look for `---\n...\n---` block
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        let prefix = "\(field):"
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.lowercased().hasPrefix(prefix) {
                var value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return nil
    }
}
