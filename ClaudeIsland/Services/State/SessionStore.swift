//
//  SessionStore.swift
//  ClaudeIsland
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.codeisland", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Sync debounce interval. 50ms (was 100ms) — iPhone users felt the
    /// lag between Claude finishing a line and seeing it on the app; 50ms
    /// still coalesces FSEvents bursts effectively while halving the floor
    /// latency for Mac→iPhone message sync.
    private let syncDebounceNs: UInt64 = 50_000_000

    /// Process liveness checker (injectable for testing)
    private let livenessChecker: ProcessLivenessChecker

    /// Background task for periodic zombie session scanning
    private var zombieScanTask: Task<Void, Never>?

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    /// Get current sessions snapshot
    func currentSessions() -> [SessionState] {
        return Array(sessions.values)
    }

    /// Look up a session by its stable UI identity (pid-sessionId composite).
    func session(withStableId stableId: String) -> SessionState? {
        return sessions.values.first(where: { $0.stableId == stableId })
    }

    // MARK: - Initialization

    init(livenessChecker: ProcessLivenessChecker = PosixLivenessChecker()) {
        self.livenessChecker = livenessChecker
    }

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .questionAnswered(let sessionId, let toolUseId, _):
            processQuestionAnswered(sessionId: sessionId, toolUseId: toolUseId)

        case .questionSkipped(let sessionId, let toolUseId):
            processQuestionSkipped(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break

        case .clearEndedSessions:
            clearEndedSessions()
        }

        publishState()
    }

    /// Update conversationInfo for a session (called from ClaudeSessionMonitor)
    func updateConversationInfo(sessionId: String, info: ConversationInfo) {
        guard var session = sessions[sessionId] else { return }
        session.conversationInfo = info
        sessions[sessionId] = session
        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.sessionId
        let isNewSession = sessions[sessionId] == nil
        DebugLogger.log("Hook", "\(event.event) status=\(event.status) sid=\(sessionId.prefix(8)) new=\(isNewSession)")

        // Q2: Codex TUI 每次启动都生成一个新 UUIDv7 作为 session_id，matcher
        // `startup|resume` 让每次 TUI 打开都触发一次 SessionStart。如果据此建
        // session 条目，用户每开一次 Codex TUI（哪怕还没输入任何 prompt）都会
        // 多一条空白会话。跳过 Codex 的首次 SessionStart，等真正的
        // UserPromptSubmit 到来再 createSession。Claude 行为不受影响。
        if isNewSession && event.source == "codex" && event.event == "SessionStart" {
            DebugLogger.log("Hook", "skipped Codex SessionStart — wait for UserPromptSubmit")
            return
        }

        var session = sessions[sessionId] ?? createSession(from: event)

        session.pid = event.pid
        // Plumb cmux workspace/surface IDs captured by the hook script from its
        // own environment. This is the only reliable source — ps -E doesn't
        // expose env vars for hardened-runtime claude processes.
        if let wsId = event.cmuxWorkspaceId, !wsId.isEmpty {
            session.cmuxWorkspaceId = wsId
        }
        if let surfId = event.cmuxSurfaceId, !surfId.isEmpty {
            session.cmuxSurfaceId = surfId
        }
        if event.source == "codex" {
            // Codex sessions: always set "Codex" as terminal app, skip process tree
            session.terminalApp = "Codex"
            if let transcriptPath = event.transcriptPath, !transcriptPath.isEmpty {
                session.codexTranscriptPath = transcriptPath
            }
        } else if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
            // Detect terminal app name
            if session.terminalApp == nil,
               let termPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: pid, tree: tree),
               let termInfo = tree[termPid] {
                let command = URL(fileURLWithPath: termInfo.command).lastPathComponent
                session.terminalApp = TerminalAppRegistry.displayName(for: command)
                // Resolve the terminal's bundle id too — lets the jumper
                // activate IDE-style hosts (VS Code, Cursor, …) directly
                // instead of probing unrelated terminals (issue #80).
                if session.hostAppBundleId == nil {
                    session.hostAppBundleId = HostAppResolver.hostApp(startingAt: termPid, tree: tree)?.bundleId
                }
            }
            // Registry miss — Claude may live inside an app we don't list
            // as a terminal (Obsidian's terminal plugin, JetBrains IDEs,
            // the Claude desktop app…). Walk the ancestry to the nearest
            // regular GUI app so "go to terminal" activates the real host
            // instead of a random terminal (issue #94).
            if session.terminalApp == nil,
               let host = HostAppResolver.hostApp(startingAt: pid, tree: tree) {
                session.terminalApp = host.name
                session.hostAppBundleId = host.bundleId
            }
            // Fall back to env-detected terminal hint from hook script
            if session.terminalApp == nil {
                session.terminalApp = event.terminalApp
            }
            if isNewSession {
                DebugLogger.log("Hook", "pid=\(pid) tmux=\(session.isInTmux) termApp=\(session.terminalApp ?? "nil") host=\(session.hostAppBundleId ?? "nil")")
            }
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()
        if Self.eventAdvancesTurnNonce(event) {
            session.currentTurnNonce &+= 1
        }

        if event.status == "ended" {
            session.phase = .ended
            session.endedAt = Date()
            sessions[sessionId] = session
            cancelPendingSync(sessionId: sessionId)
            publishState()
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        // Clean up pending question when PostToolUse arrives for AskUserQuestion
        if event.event == "PostToolUse" && event.tool == "AskUserQuestion" {
            if session.phase.isWaitingForQuestion {
                session.phase = .processing
            }
        }

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
            // Timestamp the Stop event. CompletionPanelController keys off
            // this to fire the claudeStop variant. Kept separate from
            // lastActivity (which bumps on ANY hook) so we don't need to
            // guess whether a given publisher frame was a completion.
            //
            // Dedup: Claude Code emits back-to-back Stop hooks during
            // network-retry cascades (disconnect → API error → retry → API
            // error → …). Each retry produces a fresh processing →
            // waitingForInput transition and another Stop. Collapsing Stops
            // for the same Claude work turn prevents the completion panel
            // (and downstream consumers) from firing twice when Claude later
            // emits a follow-up Stop for the hook's own return path.
            let now = Date()
            if session.lastCompletedTurnNonce == session.currentTurnNonce {
                let delta = session.lastStopAt.map { now.timeIntervalSince($0) } ?? 0
                DebugLogger.log("Store", "Stop deduped same-turn (Δ=\(String(format: "%.2f", delta))s) sid=\(sessionId.prefix(8)) nonce=\(session.currentTurnNonce)")
            } else if let prev = session.lastStopAt, now.timeIntervalSince(prev) < 3.0 {
                DebugLogger.log("Store", "Stop deduped short-window (Δ=\(String(format: "%.2f", now.timeIntervalSince(prev)))s) sid=\(sessionId.prefix(8))")
            } else {
                session.lastStopAt = now
                session.lastCompletedTurnNonce = session.currentTurnNonce
            }
        }

        // Parse conversationInfo only when needed (not on every event — too expensive for large JSONL)
        // Skip for Codex sessions — they have no Claude JSONL file
        if event.source != "codex" &&
           (session.conversationInfo.firstUserMessage == nil ||
           (session.phase == .waitingForInput && session.conversationInfo.lastMessage == nil)) {
            DebugLogger.log("Store", "Parsing conversationInfo for \(sessionId.prefix(8))")
            let conversationInfo = await ConversationParser.shared.parse(
                sessionId: sessionId,
                cwd: event.cwd
            )
            if conversationInfo.firstUserMessage != nil {
                session.conversationInfo = conversationInfo
                DebugLogger.log("Store", "Got: first=\(conversationInfo.firstUserMessage?.prefix(30) ?? "nil")")
            }
        }

        sessions[sessionId] = session
        publishState()

        if event.source == "codex" {
            // Codex: sync chat history from rollout JSONL instead of Claude JSONL
            if let transcriptPath = session.codexTranscriptPath, event.shouldSyncFile {
                scheduleCodexHistorySync(sessionId: sessionId, transcriptPath: transcriptPath)
            }
        } else if event.shouldSyncFile {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd)
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle
        )
    }

    private static func eventAdvancesTurnNonce(_ event: HookEvent) -> Bool {
        switch event.event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return true
        default:
            return false
        }
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && toolName != "Task" && toolName != "Agent"
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        let isAgentTool = event.tool == "Task" || event.tool == "Agent"

        switch event.event {
        case "PreToolUse":
            if isAgentTool, let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                    ?? event.toolInput?["prompt"]?.value as? String
                let shortDesc = description.map { String($0.prefix(60)) }
                session.subagentState.startTask(taskToolId: toolUseId, description: shortDesc)
                DebugLogger.log("Subagent", "Started \(event.tool ?? "?"): \(shortDesc ?? "nil")")
            }

        case "PostToolUse":
            if isAgentTool {
                DebugLogger.log("Subagent", "PostToolUse for \(event.tool ?? "?")")
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        sessions[sessionId] = session
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        sessions[sessionId] = session
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processQuestionAnswered(sessionId: String, toolUseId: String) {
        guard var session = sessions[sessionId] else { return }
        if session.phase.isWaitingForQuestion {
            session.phase = .processing
        }
        sessions[sessionId] = session
        publishState()
    }

    private func processQuestionSkipped(sessionId: String, toolUseId: String) {
        guard var session = sessions[sessionId] else { return }
        if session.phase.isWaitingForQuestion {
            session.phase = .processing
        }
        sessions[sessionId] = session
        publishState()
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        DebugLogger.log("FileUpdate", "sid=\(payload.sessionId.prefix(8)) msgs=\(payload.messages.count) inc=\(payload.isIncremental)")

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.sessionId,
            cwd: session.cwd
        )
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        if payload.isIncremental {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }
        } else {
            let existingIds = Set(session.chatItems.map { $0.id })

            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    if case .toolUse(let tool) = block {
                        if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }) {
                            if case .toolCall(let existingTool) = session.chatItems[idx].type {
                                session.chatItems[idx] = ChatHistoryItem(
                                    id: tool.id,
                                    type: .toolCall(ToolCallItem(
                                        name: tool.name,
                                        input: tool.input,
                                        status: existingTool.status,
                                        result: existingTool.result,
                                        structuredResult: existingTool.structuredResult,
                                        subagentTools: existingTool.subagentTools
                                    )),
                                    timestamp: message.timestamp
                                )
                            }
                            continue
                        }
                    }

                    let item = createChatItem(
                        from: block,
                        message: message,
                        blockIndex: blockIndex,
                        existingIds: existingIds,
                        completedTools: payload.completedToolIds,
                        toolResults: payload.toolResults,
                        structuredResults: payload.structuredResults,
                        toolTracker: &session.toolTracker
                    )

                    if let item = item {
                        session.chatItems.append(item)
                    }
                }
            }

            sortChatItemsInDisplayOrder(&session.chatItems)
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Populate subagent tools for Task tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.name == "Task",
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    /// Create chat item (checks existingIds to avoid duplicates)
    private func createChatItem(
        from block: MessageBlock,
        message: ChatMessage,
        blockIndex: Int,
        existingIds: Set<String>,
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        toolTracker: inout ToolTracker
    ) -> ChatHistoryItem? {
        switch block {
        case .text(let text):
            let itemId = "\(message.id)-text-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }

            if message.role == .user {
                return ChatHistoryItem(id: itemId, type: .user(text), timestamp: message.timestamp)
            } else {
                return ChatHistoryItem(id: itemId, type: .assistant(text), timestamp: message.timestamp)
            }

        case .toolUse(let tool):
            guard toolTracker.markSeen(tool.id) else { return nil }

            let isCompleted = completedTools.contains(tool.id)
            let status: ToolStatus = isCompleted ? .success : .running

            // Extract result text for completed tools
            var resultText: String? = nil
            if isCompleted, let parserResult = toolResults[tool.id] {
                if let stdout = parserResult.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = parserResult.content, !content.isEmpty {
                    resultText = content
                }
            }

            return ChatHistoryItem(
                id: tool.id,
                type: .toolCall(ToolCallItem(
                    name: tool.name,
                    input: tool.input,
                    status: status,
                    result: resultText,
                    structuredResult: structuredResults[tool.id],
                    subagentTools: []
                )),
                timestamp: message.timestamp
            )

        case .thinking(let text):
            let itemId = "\(message.id)-thinking-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .thinking(text), timestamp: message.timestamp)

        case .interrupted:
            let itemId = "\(message.id)-interrupted-\(blockIndex)"
            guard !existingIds.contains(itemId) else { return nil }
            return ChatHistoryItem(id: itemId, type: .interrupted, timestamp: message.timestamp)
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Zombie Session Detection

    /// Start periodic scanning for zombie sessions (process died without sending SessionEnd)
    func startZombieScan(interval: TimeInterval = 30) {
        zombieScanTask?.cancel()
        zombieScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.scanForZombies()
            }
        }
    }

    /// Stop the zombie scanner
    func stopZombieScan() {
        zombieScanTask?.cancel()
        zombieScanTask = nil
    }

    /// Check all non-ended sessions for dead processes, and auto-clean stale ended sessions
    func scanForZombies() {
        var changed = false
        var zombieSessionIds: [String] = []

        // 1. Detect zombie sessions (dead processes)
        for (sessionId, session) in sessions {
            guard session.phase != .ended else { continue }
            guard let pid = session.pid else { continue }
            if !livenessChecker.isAlive(pid: pid) {
                Self.logger.info("Zombie detected: session \(sessionId.prefix(8), privacy: .public) PID \(pid) is dead")
                sessions[sessionId]?.phase = .ended
                sessions[sessionId]?.endedAt = Date()
                cancelPendingSync(sessionId: sessionId)
                zombieSessionIds.append(sessionId)
                changed = true
            }
        }

        // 2. Auto-clean ended sessions older than 1 hour
        let staleThreshold = Date().addingTimeInterval(-3600) // 1 hour
        let staleIds = sessions.filter { _, session in
            session.phase == .ended && (session.endedAt ?? session.lastActivity) < staleThreshold
        }.map(\.key)
        for id in staleIds {
            Self.logger.info("Auto-cleaning stale ended session: \(id.prefix(8), privacy: .public)")
            sessions.removeValue(forKey: id)
            cancelPendingSync(sessionId: id)
            changed = true
        }

        if changed {
            for sessionId in zombieSessionIds {
                Task { @MainActor in
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: sessionId)
                    InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
                }
            }
            publishState()
        }
    }

    /// Remove all ended sessions from state
    private func clearEndedSessions() {
        let endedIds = sessions.filter { $0.value.phase == .ended }.map(\.key)
        for id in endedIds {
            sessions.removeValue(forKey: id)
            cancelPendingSync(sessionId: id)
        }
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
        // Clean up watchers and pending permissions (mirrors zombie cleanup)
        Task { @MainActor in
            HookSocketServer.shared.cancelPendingPermissions(sessionId: sessionId)
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }

    // MARK: - History Loading

    private static func sanitizedCodexPreview(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }

        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: #"<image\b[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"</image>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\[Image #[^\]]+\]"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        // Codex sessions: parse rollout JSONL instead of Claude JSONL
        if let transcriptPath = sessions[sessionId]?.codexTranscriptPath, !transcriptPath.isEmpty {
            let messages = await CodexChatHistoryParser.shared.parse(transcriptPath: transcriptPath)
            let firstUserMsg = messages.first(where: { $0.role == .user })
            let lastUserMsg = messages.last(where: { $0.role == .user })
            let conversationInfo = ConversationInfo(
                summary: nil,
                lastMessage: Self.sanitizedCodexPreview(messages.last?.textContent, maxLength: 80),
                lastMessageRole: messages.last?.role.rawValue,
                lastToolName: nil,
                firstUserMessage: Self.sanitizedCodexPreview(firstUserMsg?.textContent, maxLength: 50),
                latestUserMessage: Self.sanitizedCodexPreview(lastUserMsg?.textContent, maxLength: 60),
                lastUserMessageDate: lastUserMsg?.timestamp
            )
            await process(.historyLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: [],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: conversationInfo
            ))
            return
        }

        // Claude sessions: parse from JSONL
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        DebugLogger.log("HistLoad", "sid=\(sessionId.prefix(8)) msgs=\(messages.count) existing=\(session.chatItems.count)")

        // Convert messages to chat items
        let existingIds = Set(session.chatItems.map { $0.id })
        var addedCount = 0

        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                let item = createChatItem(
                    from: block,
                    message: message,
                    blockIndex: blockIndex,
                    existingIds: existingIds,
                    completedTools: completedTools,
                    toolResults: toolResults,
                    structuredResults: structuredResults,
                    toolTracker: &session.toolTracker
                )

                if let item = item {
                    session.chatItems.append(item)
                    addedCount += 1
                }
            }
        }

        DebugLogger.log("HistLoad", "Added \(addedCount) items, total=\(session.chatItems.count)")

        // Preserve source order for same-timestamp items so the latest
        // user/assistant turn does not get scrambled in quick panel summary.
        sortChatItemsInDisplayOrder(&session.chatItems)

        sessions[sessionId] = session
        publishState()
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func scheduleCodexHistorySync(sessionId: String, transcriptPath: String) {
        cancelPendingSync(sessionId: sessionId)

        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            let messages = await CodexChatHistoryParser.shared.parse(transcriptPath: transcriptPath)
            guard !messages.isEmpty else { return }

            let firstUserMsg = messages.first(where: { $0.role == .user })
            let lastUserMsg = messages.last(where: { $0.role == .user })
            let conversationInfo = ConversationInfo(
                summary: nil,
                lastMessage: Self.sanitizedCodexPreview(messages.last?.textContent, maxLength: 80),
                lastMessageRole: messages.last?.role.rawValue,
                lastToolName: nil,
                firstUserMessage: Self.sanitizedCodexPreview(firstUserMsg?.textContent, maxLength: 50),
                latestUserMessage: Self.sanitizedCodexPreview(lastUserMsg?.textContent, maxLength: 60),
                lastUserMessageDate: lastUserMsg?.timestamp
            )
            await self?.process(.historyLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: [],
                toolResults: [:],
                structuredResults: [:],
                conversationInfo: conversationInfo
            ))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    private func sortChatItemsInDisplayOrder(_ items: inout [ChatHistoryItem]) {
        items = items.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
