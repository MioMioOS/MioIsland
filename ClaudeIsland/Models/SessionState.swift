//
//  SessionState.swift
//  ClaudeIsland
//
//  Unified state model for a Claude session.
//  Consolidates all state that was previously spread across multiple components.
//

import Foundation

/// Complete state for a single Claude session
/// This is the single source of truth - all state reads and writes go through SessionStore
struct SessionState: Equatable, Identifiable, Sendable {
    // MARK: - Identity

    let sessionId: String
    let cwd: String
    let projectName: String

    // MARK: - Instance Metadata

    var pid: Int?
    var tty: String?
    var isInTmux: Bool
    /// Detected terminal app name (e.g., "Ghostty", "Warp", "iTerm2", "cmux", "Terminal")
    var terminalApp: String?
    /// Bundle id of the GUI app that actually hosts the session — either the
    /// registered terminal's own bundle, or (registry miss) the nearest
    /// regular-app ancestor such as Obsidian, a JetBrains IDE or the Claude
    /// desktop app. Lets the jumper activate the real host instead of
    /// probing unrelated terminals (issues #94 / #80).
    var hostAppBundleId: String?
    /// cmux workspace/surface IDs captured by the hook script from its own
    /// `os.environ` (inherited from claude → cmux shell). The only reliable
    /// way to read these — `ps -E` on macOS hides env vars of hardened-runtime
    /// processes, so we can't query them after the fact.
    var cmuxWorkspaceId: String?
    var cmuxSurfaceId: String?
    /// Codex rollout transcript path (non-nil for Codex sessions)
    var codexTranscriptPath: String?

    // MARK: - State Machine

    /// Current phase in the session lifecycle
    var phase: SessionPhase

    // MARK: - Chat History

    /// All chat items for this session (replaces ChatHistoryManager.histories)
    var chatItems: [ChatHistoryItem]

    // MARK: - Tool Tracking

    /// Unified tool tracker (replaces 6+ dictionaries in ChatHistoryManager)
    var toolTracker: ToolTracker

    // MARK: - Subagent State

    /// State for Task tools and their nested subagent tools
    var subagentState: SubagentState

    // MARK: - Conversation Info (from JSONL parsing)

    var conversationInfo: ConversationInfo

    // MARK: - Clear Reconciliation

    /// When true, the next file update should reconcile chatItems with parser state
    /// This removes pre-/clear items that no longer exist in the JSONL
    var needsClearReconciliation: Bool

    // MARK: - Timestamps

    var lastActivity: Date
    var createdAt: Date
    /// When the session was marked as ended (for auto-cleanup after timeout)
    var endedAt: Date?
    /// Most recent Stop hook timestamp. Written only by the Stop-event
    /// handler, so any change = a real "Claude just finished this turn"
    /// signal (unlike `lastActivity` which also bumps on tool events).
    /// CompletionPanelController watches this to trigger the claudeStop
    /// variant — robust against SubagentStop → Stop sequences where the
    /// session is already in waitingForInput before the true Stop hook
    /// arrives, which phase-diff detection can't distinguish.
    var lastStopAt: Date?
    /// Monotonic token for the current Claude work turn. Advances when the
    /// user submits a prompt or the turn produces tool activity.
    var currentTurnNonce: Int
    /// The turn nonce that already emitted a completion Stop.
    var lastCompletedTurnNonce: Int?

    // MARK: - Identifiable

    var id: String { sessionId }

    // MARK: - Initialization

    nonisolated init(
        sessionId: String,
        cwd: String,
        projectName: String? = nil,
        pid: Int? = nil,
        tty: String? = nil,
        isInTmux: Bool = false,
        terminalApp: String? = nil,
        phase: SessionPhase = .idle,
        chatItems: [ChatHistoryItem] = [],
        toolTracker: ToolTracker = ToolTracker(),
        subagentState: SubagentState = SubagentState(),
        conversationInfo: ConversationInfo = ConversationInfo(
            summary: nil, lastMessage: nil, lastMessageRole: nil,
            lastToolName: nil, firstUserMessage: nil, latestUserMessage: nil, lastUserMessageDate: nil
        ),
        needsClearReconciliation: Bool = false,
        lastActivity: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
        self.pid = pid
        self.tty = tty
        self.isInTmux = isInTmux
        self.terminalApp = terminalApp
        self.phase = phase
        self.chatItems = chatItems
        self.toolTracker = toolTracker
        self.subagentState = subagentState
        self.conversationInfo = conversationInfo
        self.needsClearReconciliation = needsClearReconciliation
        self.lastActivity = lastActivity
        self.createdAt = createdAt
        self.currentTurnNonce = 0
        self.lastCompletedTurnNonce = nil
    }

    // MARK: - Derived Properties

    /// Whether this session needs user attention
    var needsAttention: Bool {
        phase.needsAttention
    }

    /// The active permission context, if any
    var activePermission: PermissionContext? {
        if case .waitingForApproval(let ctx) = phase {
            return ctx
        }
        return nil
    }

    // MARK: - UI Convenience Properties

    /// Stable identity for SwiftUI (combines PID and sessionId for animation stability)
    var stableId: String {
        if let pid = pid {
            return "\(pid)-\(sessionId)"
        }
        return sessionId
    }

    /// Whether this session is backed by the Codex CLI rather than Claude Code.
    var isCodexSession: Bool {
        if let transcriptPath = codexTranscriptPath, !transcriptPath.isEmpty {
            return true
        }
        let app = terminalApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return app == "codex"
    }

    /// Whether this session is backed by a GPT/OpenAI GUI surface.
    var isGPTSession: Bool {
        guard !isCodexSession else { return false }
        let app = terminalApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return app.contains("chatgpt") || app == "gpt" || app.contains("openai")
    }

    /// Human-facing agent badge shown in the sessions list.
    var agentTag: String {
        if isCodexSession { return "Codex" }
        if isGPTSession { return "GPT" }
        return "Claude"
    }

    /// SF Symbol used to visually distinguish the agent surface.
    var agentIconSymbolName: String {
        if isCodexSession { return "chevron.left.forwardslash.chevron.right" }
        if isGPTSession { return "sparkles" }
        return "sun.max"
    }

    /// Whether the session is using a GUI app surface rather than a terminal multiplexer.
    var isGraphicalTerminalSurface: Bool {
        guard cmuxWorkspaceId?.isEmpty != false,
              cmuxSurfaceId?.isEmpty != false,
              !isInTmux else { return false }
        let app = terminalApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return app == "codex" || app.contains("chatgpt") || app == "gpt" || app.contains("openai")
    }

    /// SF Symbol used for the terminal/backend indicator in the sessions list.
    var terminalIconSymbolName: String {
        let tag = terminalTag.lowercased()
        if isGraphicalTerminalSurface { return "macwindow" }
        if tag.contains("cmux") { return "square.split.2x1" }
        if tag.contains("tmux") { return "square.grid.2x2" }
        return "terminal"
    }

    /// Human-facing terminal badge shown in the sessions list.
    var terminalTag: String {
        if let wsId = cmuxWorkspaceId, !wsId.isEmpty {
            return "cmux"
        }
        if let surfId = cmuxSurfaceId, !surfId.isEmpty {
            return "cmux"
        }
        if isInTmux {
            return "tmux"
        }
        if let app = terminalApp?.trimmingCharacters(in: .whitespacesAndNewlines),
           !app.isEmpty {
            let lower = app.lowercased()
            if lower == "codex" || lower.contains("chatgpt") || lower == "gpt" || lower.contains("openai") {
                return "Terminal"
            }
            if lower != "claude" {
                return app
            }
        }
        return "Terminal"
    }

    /// Display title: summary > latest user message > first user message > project name
    var displayTitle: String {
        conversationInfo.summary ?? conversationInfo.latestUserMessage ?? conversationInfo.firstUserMessage ?? projectName
    }

    /// Smart one-line summary synthesized from session data.
    /// - If `conversationInfo.summary` exists, use it directly.
    /// - Otherwise construct: "[firstUserMessage truncated to 30 chars] → [lastToolName]: [lastMessage truncated to 40 chars]"
    /// - If no firstUserMessage, use projectName.
    /// - If no lastToolName, skip the arrow part.
    var smartSummary: String? {
        if let summary = conversationInfo.summary {
            return summary
        }

        let prefix: String
        if let latest = conversationInfo.latestUserMessage {
            prefix = latest.count > 30 ? String(latest.prefix(30)) + "..." : latest
        } else if let first = conversationInfo.firstUserMessage {
            prefix = first.count > 30 ? String(first.prefix(30)) + "..." : first
        } else {
            prefix = projectName
        }

        if let toolName = conversationInfo.lastToolName {
            let lastPart: String
            if let last = conversationInfo.lastMessage {
                lastPart = last.count > 40 ? String(last.prefix(40)) + "..." : last
            } else {
                lastPart = ""
            }
            if lastPart.isEmpty {
                return "\(prefix) → \(toolName)"
            }
            return "\(prefix) → \(toolName): \(lastPart)"
        }

        // No tool name — just return prefix if we have any useful info
        if conversationInfo.firstUserMessage != nil || conversationInfo.lastMessage != nil {
            if let last = conversationInfo.lastMessage {
                let lastPart = last.count > 40 ? String(last.prefix(40)) + "..." : last
                return "\(prefix): \(lastPart)"
            }
            return prefix
        }

        // Fallback: directly read JSONL to extract first user message
        if let msg = Self.directParseFirstMessage(sessionId: sessionId, cwd: cwd) {
            return msg
        }
        // Ultimate fallback: show cwd and sessionId for debugging
        return nil
    }

    /// Emergency fallback: read JSONL directly without going through ConversationParser
    private static func directParseFirstMessage(sessionId: String, cwd: String) -> String? {
        // Try exact cwd first, then walk up parent directories
        var searchCwd = cwd
        let projectsDir = ConfigPaths.claudeProjectsDir.path

        while !searchCwd.isEmpty && searchCwd != "/" {
            let projectDir = searchCwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
            let path = projectsDir + "/" + projectDir + "/" + sessionId + ".jsonl"
            if FileManager.default.fileExists(atPath: path) {
                return parseFirstUserMessage(from: path)
            }
            // Go up one directory
            searchCwd = (searchCwd as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func parseFirstUserMessage(from path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Scan from end: find last user message + last assistant text
        var lastUserMsg: String?
        var lastAssistantMsg: String?

        for line in lines.reversed().prefix(500) {
            guard let ld = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let type = json["type"] as? String,
                  !(json["isMeta"] as? Bool ?? false),
                  let msg = json["message"] as? [String: Any] else { continue }

            let text = Self.extractText(from: msg)
            guard let t = text else { continue }

            if type == "assistant" && lastAssistantMsg == nil {
                lastAssistantMsg = String(t.prefix(80))
            }
            if type == "user" && lastUserMsg == nil {
                lastUserMsg = String(t.prefix(40))
            }
            if lastUserMsg != nil && lastAssistantMsg != nil { break }
        }

        // Build summary: "你: [question] → [claude reply]"
        if let user = lastUserMsg, let assistant = lastAssistantMsg {
            let userPart = user.count > 30 ? String(user.prefix(30)) + "..." : user
            let assistPart = assistant.count > 50 ? String(assistant.prefix(50)) + "..." : assistant
            return "\(userPart)\n\(assistPart)"
        }
        if let assistant = lastAssistantMsg {
            return assistant
        }
        return lastUserMsg
    }

    /// Extract text content from a message (handles both String and Array formats)
    private static func extractText(from msg: [String: Any]) -> String? {
        if let c = msg["content"] as? String,
           !c.hasPrefix("<command-name>"), !c.hasPrefix("<local-command"), !c.hasPrefix("Caveat:") {
            return c
        }
        if let arr = msg["content"] as? [[String: Any]] {
            for b in arr {
                if b["type"] as? String == "text",
                   let t = b["text"] as? String,
                   !t.hasPrefix("<command-name>"), !t.hasPrefix("<local-command"), !t.hasPrefix("Caveat:"),
                   !t.hasPrefix("[Request interrupted") {
                    return t
                }
            }
        }
        return nil
    }

    /// Best hint for matching window title
    var windowHint: String {
        conversationInfo.summary ?? projectName
    }

    /// Pending tool name if waiting for approval
    var pendingToolName: String? {
        activePermission?.toolName
    }

    /// Pending tool use ID
    var pendingToolId: String? {
        activePermission?.toolUseId
    }

    /// Formatted pending tool input for display
    var pendingToolInput: String? {
        activePermission?.formattedInput
    }

    /// Last message content
    var lastMessage: String? {
        conversationInfo.lastMessage
    }

    /// Last message role
    var lastMessageRole: String? {
        conversationInfo.lastMessageRole
    }

    /// Last tool name
    var lastToolName: String? {
        conversationInfo.lastToolName
    }

    /// Summary
    var summary: String? {
        conversationInfo.summary
    }

    /// First user message
    var firstUserMessage: String? {
        conversationInfo.firstUserMessage
    }

    /// Last user message date
    var lastUserMessageDate: Date? {
        conversationInfo.lastUserMessageDate
    }

    /// Whether the session can be interacted with
    var canInteract: Bool {
        phase.needsAttention
    }

    /// True when the session has produced no user-visible content at all:
    /// no tool calls, no chat items, no parsed conversation info.
    ///
    /// Used as a safety net to suppress notifications (bounce / sound /
    /// auto-popup) for "empty shell" sessions — typically claude-mem style
    /// plugin-spawned Claude children that fire SessionStart + Stop within
    /// seconds and never accept a user prompt. Also protects against any
    /// future event source that produces malformed / partial hook payloads.
    var hasNoContentYet: Bool {
        toolTracker.seenIds.isEmpty
            && chatItems.isEmpty
            && conversationInfo.firstUserMessage == nil
            && conversationInfo.lastMessage == nil
            && conversationInfo.summary == nil
    }
}

// MARK: - Tool Tracker

/// Unified tool tracking - replaces multiple dictionaries in ChatHistoryManager
struct ToolTracker: Equatable, Sendable {
    /// Tools currently in progress, keyed by tool_use_id
    var inProgress: [String: ToolInProgress]

    /// All tool IDs we've seen (for deduplication)
    var seenIds: Set<String>

    /// Last JSONL file offset for incremental parsing
    var lastSyncOffset: UInt64

    /// Last sync timestamp
    var lastSyncTime: Date?

    nonisolated init(
        inProgress: [String: ToolInProgress] = [:],
        seenIds: Set<String> = [],
        lastSyncOffset: UInt64 = 0,
        lastSyncTime: Date? = nil
    ) {
        self.inProgress = inProgress
        self.seenIds = seenIds
        self.lastSyncOffset = lastSyncOffset
        self.lastSyncTime = lastSyncTime
    }

    /// Mark a tool ID as seen, returns true if it was new
    nonisolated mutating func markSeen(_ id: String) -> Bool {
        seenIds.insert(id).inserted
    }

    /// Check if a tool ID has been seen
    nonisolated func hasSeen(_ id: String) -> Bool {
        seenIds.contains(id)
    }

    /// Start tracking a tool
    nonisolated mutating func startTool(id: String, name: String) {
        guard markSeen(id) else { return }
        inProgress[id] = ToolInProgress(
            id: id,
            name: name,
            startTime: Date(),
            phase: .running
        )
    }

    /// Complete a tool
    nonisolated mutating func completeTool(id: String, success: Bool) {
        inProgress.removeValue(forKey: id)
    }
}

/// A tool currently in progress
struct ToolInProgress: Equatable, Sendable {
    let id: String
    let name: String
    let startTime: Date
    var phase: ToolInProgressPhase
}

/// Phase of a tool in progress
enum ToolInProgressPhase: Equatable, Sendable {
    case starting
    case running
    case pendingApproval
}

// MARK: - Subagent State

/// State for Task (subagent) tools
struct SubagentState: Equatable, Sendable {
    /// Active Task tools, keyed by task tool_use_id
    var activeTasks: [String: TaskContext]

    /// Ordered stack of active task IDs (most recent last) - used for proper tool assignment
    /// When multiple Tasks run in parallel, we use insertion order rather than timestamps
    var taskStack: [String]

    /// Mapping of agentId to Task description (for AgentOutputTool display)
    var agentDescriptions: [String: String]

    nonisolated init(activeTasks: [String: TaskContext] = [:], taskStack: [String] = [], agentDescriptions: [String: String] = [:]) {
        self.activeTasks = activeTasks
        self.taskStack = taskStack
        self.agentDescriptions = agentDescriptions
    }

    /// Whether there's an active subagent
    nonisolated var hasActiveSubagent: Bool {
        !activeTasks.isEmpty
    }

    /// Start tracking a Task tool
    nonisolated mutating func startTask(taskToolId: String, description: String? = nil) {
        activeTasks[taskToolId] = TaskContext(
            taskToolId: taskToolId,
            startTime: Date(),
            agentId: nil,
            description: description,
            subagentTools: []
        )
    }

    /// Stop tracking a Task tool
    nonisolated mutating func stopTask(taskToolId: String) {
        activeTasks.removeValue(forKey: taskToolId)
    }

    /// Set the agentId for a Task (called when agent file is discovered)
    nonisolated mutating func setAgentId(_ agentId: String, for taskToolId: String) {
        activeTasks[taskToolId]?.agentId = agentId
        if let description = activeTasks[taskToolId]?.description {
            agentDescriptions[agentId] = description
        }
    }

    /// Add a subagent tool to a specific Task by ID
    nonisolated mutating func addSubagentToolToTask(_ tool: SubagentToolCall, taskId: String) {
        activeTasks[taskId]?.subagentTools.append(tool)
    }

    /// Set all subagent tools for a specific Task (used when updating from agent file)
    nonisolated mutating func setSubagentTools(_ tools: [SubagentToolCall], for taskId: String) {
        activeTasks[taskId]?.subagentTools = tools
    }

    /// Add a subagent tool to the most recent active Task
    nonisolated mutating func addSubagentTool(_ tool: SubagentToolCall) {
        // Find most recent active task (for parallel Task support)
        guard let mostRecentTaskId = activeTasks.keys.max(by: {
            (activeTasks[$0]?.startTime ?? .distantPast) < (activeTasks[$1]?.startTime ?? .distantPast)
        }) else { return }

        activeTasks[mostRecentTaskId]?.subagentTools.append(tool)
    }

    /// Update the status of a subagent tool across all active Tasks
    nonisolated mutating func updateSubagentToolStatus(toolId: String, status: ToolStatus) {
        for taskId in activeTasks.keys {
            if let index = activeTasks[taskId]?.subagentTools.firstIndex(where: { $0.id == toolId }) {
                activeTasks[taskId]?.subagentTools[index].status = status
                return
            }
        }
    }
}

/// Context for an active Task tool
struct TaskContext: Equatable, Sendable {
    let taskToolId: String
    let startTime: Date
    var agentId: String?
    var description: String?
    var subagentTools: [SubagentToolCall]
}
