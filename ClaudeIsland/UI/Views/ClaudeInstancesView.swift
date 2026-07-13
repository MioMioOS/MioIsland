//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import AppKit
import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel

    /// Tracks which project groups are collapsed, keyed by group id (cwd path)
    @State private var collapsedGroups: Set<String> = []
    /// Whether to show grouped by project or flat list (default: flat)
    @AppStorage("showGroupedSessions") private var showGrouped: Bool = false
    @ObservedObject private var buddyReader = BuddyReader.shared
    @State private var showBuddyCard: Bool = false
    @AppStorage("usePixelCat") private var usePixelCat: Bool = false
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    @ObservedObject private var hiddenStore: HiddenProjectsStore = .shared
    /// Pending "hide group" confirmation: set when user clicks the move button.
    @State private var pendingHide: PendingHide? = nil
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    private struct PendingHide: Identifiable {
        let id = UUID()
        let cwd: String
        let name: String
    }

    var body: some View {
        if sessionMonitor.instances.isEmpty {
            emptyState
        } else {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    // Top bar: session count + settings
                    HStack {
                        Text("\(sessionMonitor.instances.count) \(L10n.sessions)")
                            .notchFont(11)
                            .notchSecondaryForeground()
                        Spacer()

                        // Plugin header buttons
                        PluginHeaderButtons(viewModel: viewModel)

                        HeaderIconButton(icon: "gearshape", hoverColor: Color(red: 0xCA/255, green: 0xFF/255, blue: 0x00/255)) {
                            SystemSettingsWindow.shared.show()
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)

                    if showBuddyCard, let buddy = buddyReader.buddy {
                        buddyCardView(buddy)
                    } else if showGrouped {
                        groupedList
                    } else {
                        flatList
                    }
                }
                .padding(.bottom, 50)

                // Bottom right: buddy + usage stats
                // Hidden when buddy card open or when expanded with many sessions
                // Also honor the user's showBuddy / showUsageBar preferences.
                if !showBuddyCard && !(sortedInstances.count > 4 && viewModel.isInstancesExpanded)
                    && (notchStore.customization.showBuddy || notchStore.customization.showUsageBar) {
                    VStack(alignment: .trailing, spacing: 4) {
                        // Only show buddy when ≤ 5 sessions AND the user has
                        // the showBuddy preference enabled.
                        if notchStore.customization.showBuddy,
                           sortedInstances.count <= 5,
                           let buddy = buddyReader.buddy {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showBuddyCard.toggle()
                                }
                            } label: {
                                BuddyASCIIView(buddy: buddy)
                                    .frame(width: 80, height: 50)
                                    .scaleEffect(0.7)
                            }
                            .buttonStyle(.plain)
                        }

                        if notchStore.customization.showUsageBar {
                            // Tokens mode shows ONE unified cross-model bar
                            // (replacing both plan bars). Otherwise the Claude
                            // plan-% bar, gated on its sub-toggle.
                            if notchStore.customization.usageBarDisplayMode == .tokens {
                                TokenUsageStatsBar(monitor: tokenUsageMonitor)
                            } else if notchStore.customization.showClaudeUsageBar {
                                UsageStatsBar(monitor: rateLimitMonitor, totalMinutes: totalSessionMinutes)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 12)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Bottom left: Codex usage stats (hidden in tokens mode — the
                // unified token bar already covers Codex)
                if codexGate.isEnabled && !showBuddyCard && !(sortedInstances.count > 4 && viewModel.isInstancesExpanded)
                    && notchStore.customization.showUsageBar
                    && notchStore.customization.usageBarDisplayMode != .tokens
                    && notchStore.customization.showCodexUsageBar {
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer()
                        CodexUsageStatsBar(monitor: codexUsageMonitor)
                    }
                    .padding(.leading, 4)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .onReceive(sessionMonitor.$instances) { instances in
                viewModel.sessionCount = instances.count
                viewModel.activeSessionCount = instances.filter {
                    $0.phase != .idle && $0.phase != .ended
                }.count
            }
            // Gate the Anthropic usage API poll loop on the Usage Bar
            // preference. Previously RateLimitMonitor.shared polled the API
            // unconditionally on init, so users who disabled the bar still
            // hit api.anthropic.com every 5 minutes. See issue #50.
            // Also gate on the Claude sub-toggle so users who only want Codex
            // shown don't pay the Claude API poll cost.
            .onAppear { syncUsageMonitors() }
            .onChange(of: notchStore.customization.showUsageBar) { _, _ in syncUsageMonitors() }
            .onChange(of: notchStore.customization.showClaudeUsageBar) { _, _ in syncUsageMonitors() }
            .onChange(of: notchStore.customization.usageBarDisplayMode) { _, _ in syncUsageMonitors() }
        }
    }

    /// Single source of truth for which usage monitors should be running.
    /// Tokens mode shows the unified local-transcript meter and HIDES the plan
    /// bars, so the Anthropic usage-API poll (rateLimitMonitor) must be stopped
    /// in that mode — otherwise it keeps hitting api.anthropic.com every 5 min
    /// for a bar that isn't visible (the issue #50 regression). Leaving tokens
    /// mode restarts the plan monitor if its bar would show.
    @MainActor
    private func syncUsageMonitors() {
        let c = notchStore.customization
        let tokensMode = c.showUsageBar && c.usageBarDisplayMode == .tokens
        if tokensMode {
            tokenUsageMonitor.start()
        } else {
            tokenUsageMonitor.stop()
        }
        if c.showUsageBar && !tokensMode && c.showClaudeUsageBar {
            rateLimitMonitor.start()
        } else {
            rateLimitMonitor.stop()
        }
    }

    // MARK: - Buddy Card

    @ViewBuilder
    private func buddyCardView(_ buddy: BuddyInfo) -> some View {
        VStack(spacing: 6) {
            // Header
            HStack {
                Text(buddy.rarity.stars)
                    .notchFont(11)
                    .foregroundColor(buddy.rarity.color)
                Text(buddy.rarity.displayName.uppercased())
                    .notchFont(11, weight: .bold, design: .monospaced)
                    .foregroundColor(buddy.rarity.color)
                Spacer()
                Text(buddy.species.rawValue.uppercased())
                    .notchFont(11, weight: .medium, design: .monospaced)
                    .notchSecondaryForeground()
                if buddy.isShiny {
                    Text("✨")
                        .notchFont(11)
                }
            }
            .padding(.horizontal, 10)

            // Left-right layout: ASCII art | stats
            HStack(alignment: .top, spacing: 8) {
                // Left: ASCII sprite (name shown by BuddyASCIIView)
                BuddyASCIIView(buddy: buddy)
                    .frame(width: 100, height: 65)

                // Right: stats + personality
                VStack(alignment: .leading, spacing: 4) {
                    if buddy.stats.debugging > 0 {
                        asciiStatBar("DBG", value: buddy.stats.debugging, color: .cyan)
                        asciiStatBar("PAT", value: buddy.stats.patience, color: .green)
                        asciiStatBar("CHS", value: buddy.stats.chaos, color: .red)
                        asciiStatBar("WIS", value: buddy.stats.wisdom, color: .purple)
                        asciiStatBar("SNK", value: buddy.stats.snark, color: .orange)
                    }

                    Text(buddy.personality)
                        .notchFont(8)
                        .notchSecondaryForeground()
                        .lineLimit(3)
                        .padding(.top, 3)
                }
            }
            .padding(.horizontal, 8)

            // Back
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showBuddyCard = false
                }
            } label: {
                Text(L10n.back)
                    .notchFont(11, weight: .medium)
                    .notchSecondaryForeground()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.overlay.opacity(0.18)))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    /// ASCII-style stat bar: `DBG [████████░░] 64`
    private func asciiStatBar(_ label: String, value: Int, color: Color) -> some View {
        let filled = value / 10
        let empty = 10 - filled
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)

        return HStack(spacing: 3) {
            Text(label)
                .notchFont(11, weight: .medium, design: .monospaced)
                .notchSecondaryForeground()
                .frame(width: 30, alignment: .trailing)
            Text("[\(bar)]")
                .notchFont(11, weight: .regular, design: .monospaced)
                .foregroundColor(color.opacity(0.7))
            Text("\(value)")
                .notchFont(11, weight: .regular, design: .monospaced)
                .foregroundColor(color.opacity(0.5))
                .frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: - Empty State

    @State private var emptyPulse = false
    @State private var emptyFloat = false

    private var emptyState: some View {
        VStack(spacing: 0) {
            // Top bar with settings
            HStack {
                Spacer()

                // Plugin header buttons
                PluginHeaderButtons(viewModel: viewModel)

                Button {
                    // Skip the intermediate NotchMenu — that fallback
                    // menu only contains a single "设置" row and feels
                    // redundant. Open the full SystemSettings panel
                    // directly.
                    SystemSettingsWindow.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                        .notchFont(10)
                        .notchSecondaryForeground()
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Spacer()

            // Animated pixel cat
            VStack(spacing: 12) {
                if usePixelCat {
                    PixelCharacterView(state: .idle)
                        .scaleEffect(0.8)
                        .frame(width: 52, height: 44)
                        .offset(y: emptyFloat ? -3 : 3)
                } else if let buddy = buddyReader.buddy {
                    BuddyASCIIView(buddy: buddy)
                        .frame(width: 80, height: 55)
                        .scaleEffect(0.8)
                        .offset(y: emptyFloat ? -3 : 3)
                } else {
                    PixelCharacterView(state: .idle)
                        .scaleEffect(0.8)
                        .frame(width: 52, height: 44)
                        .offset(y: emptyFloat ? -3 : 3)
                }

                Text(L10n.noSessions)
                    .notchFont(13, weight: .medium)
                    .opacity(emptyPulse ? 0.5 : 0.3)

                Text(L10n.runClaude)
                    .notchFont(10)
                    .opacity(0.2)
                    .padding(.horizontal, 20)
                    .multilineTextAlignment(.center)

                // Usage stats if available (honors showUsageBar + sub-toggles)
                if notchStore.customization.showUsageBar {
                    if notchStore.customization.usageBarDisplayMode == .tokens {
                        TokenUsageStatsBar(monitor: tokenUsageMonitor)
                            .padding(.top, 4)
                    } else {
                        if notchStore.customization.showClaudeUsageBar {
                            UsageStatsBar(monitor: rateLimitMonitor, totalMinutes: 0)
                                .padding(.top, 4)
                        }
                        if codexGate.isEnabled && notchStore.customization.showCodexUsageBar {
                            CodexUsageStatsBar(monitor: codexUsageMonitor)
                                .padding(.top, 4)
                        }
                    }
                }
            }

            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                emptyPulse = true
            }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                emptyFloat = true
            }
        }
    }

    // MARK: - Stats

    /// Total minutes across all sessions
    private var totalSessionMinutes: Int {
        sessionMonitor.instances.reduce(0) { total, session in
            total + Int(Date().timeIntervalSince(session.createdAt) / 60)
        }
    }

    /// Format total time as "Xh Ym" or "Ym"
    private func formatTotalTime(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }

    @StateObject private var rateLimitMonitor = RateLimitMonitor.shared
    @StateObject private var codexUsageMonitor = CodexUsageMonitor.shared
    @StateObject private var tokenUsageMonitor = TokenUsageMonitor.shared
    @ObservedObject private var codexGate = CodexFeatureGate.shared

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        SessionFilter.filterForDisplay(sessionMonitor.instances,
                                       isHidden: { hiddenStore.isHidden(cwd: $0) })
        .sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .waitingForQuestion, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    /// Sessions grouped by project (cwd), with per-group sorting preserved
    private var projectGroups: [ProjectGroup] {
        ProjectGroup.group(sessions: sortedInstances)
    }

    private var flatList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(sortedInstances.enumerated()), id: \.element.id) { index, session in
                    InstanceRow(
                        session: session,
                        onFocus: { focusSession(session) },
                        onChat: { openChat(session) },
                        onArchive: { archiveSession(session) },
                        onApprove: { approveSession(session) },
                        onReject: { rejectSession(session) }
                    )
                    .id(session.stableId)

                    // Subagent rows under this session
                    if session.subagentState.hasActiveSubagent {
                        SubagentListView(session: session)
                    }

                    // Gradient divider between rows
                    if index < sortedInstances.count - 1 {
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.06), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                    }
                }

                // Footer: expand/collapse when >4 sessions, or just count
                if sortedInstances.count > 4 && !viewModel.isInstancesExpanded {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            viewModel.isInstancesExpanded = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                                .notchFont(8)
                            Text(L10n.showAllSessions(sortedInstances.count))
                                .notchFont(10)
                        }
                        .notchSecondaryForeground()
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.04))
                        )
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                } else if sortedInstances.count > 4 && viewModel.isInstancesExpanded {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            viewModel.isInstancesExpanded = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.up")
                                .notchFont(8)
                            Text("收起")
                                .notchFont(10)
                        }
                        .notchSecondaryForeground()
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                } else if sortedInstances.count > 0 {
                    Text(L10n.showAllSessions(sortedInstances.count))
                        .notchFont(10)
                        .opacity(0.2)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var groupedList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(projectGroups) { group in
                    ProjectGroupHeader(
                        group: group,
                        isCollapsed: collapsedGroups.contains(group.id),
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if collapsedGroups.contains(group.id) {
                                    collapsedGroups.remove(group.id)
                                } else {
                                    collapsedGroups.insert(group.id)
                                }
                            }
                        },
                        onMoveRequested: {
                            pendingHide = PendingHide(cwd: group.id, name: group.name)
                        }
                    )

                    if !collapsedGroups.contains(group.id) {
                        ForEach(group.sessions) { session in
                            InstanceRow(
                                session: session,
                                onFocus: { focusSession(session) },
                                onChat: { openChat(session) },
                                onArchive: { archiveSession(session) },
                                onApprove: { approveSession(session) },
                                onReject: { rejectSession(session) }
                            )
                            .id(session.stableId)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .confirmationDialog(
            pendingHide.map { L10n.isChinese ? "移除「\($0.name)」" : "Hide \"\($0.name)\"" } ?? "",
            isPresented: Binding(
                get: { pendingHide != nil },
                set: { if !$0 { pendingHide = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingHide
        ) { hide in
            Button(L10n.isChinese ? "仅本次隐藏" : "Hide for this session") {
                hiddenStore.dismissForSession(cwd: hide.cwd)
                pendingHide = nil
            }
            Button(
                L10n.isChinese ? "永久加入黑名单" : "Add to permanent blacklist",
                role: .destructive
            ) {
                hiddenStore.blacklist(cwd: hide.cwd)
                pendingHide = nil
            }
            Button(L10n.isChinese ? "取消" : "Cancel", role: .cancel) {
                pendingHide = nil
            }
        } message: { hide in
            Text(hide.cwd)
        }
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        Task {
            await TerminalJumper.shared.jump(to: session)
            await MainActor.run { viewModel.notchClose() }
        }
    }

    private func openChat(_ session: SessionState) {
        // If session has AskUserQuestion pending, show the question UI instead of chat
        if session.pendingToolName == "AskUserQuestion",
           session.phase.isWaitingForApproval {
            viewModel.showQuestion(for: session)
        } else {
            viewModel.showChat(for: session)
        }
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var isHovered = false

    // MARK: - Colors

    /// Blue pill colors for "Claude" tag
    private static let claudeTagBg = Color(red: 0.145, green: 0.388, blue: 0.922).opacity(0.2) // #2563EB @ 0.2
    private static let claudeTagFg = Color(red: 0.376, green: 0.647, blue: 0.98) // #60A5FA
    private static let cyanColor = Color(red: 0.4, green: 0.91, blue: 0.98)

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Duration since session started, formatted as "<Xm" or "Xh"
    private var durationText: String {
        let elapsed = Date().timeIntervalSince(session.createdAt)
        let minutes = Int(elapsed / 60)
        if minutes < 1 {
            return "<1m"
        }
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        return "\(hours)h"
    }

    /// Agent tag color based on session source
    private var agentTagColor: Color {
        if theme.isRetroArcade { return theme.agentBadgeText }
        let tag = session.agentTag.lowercased()
        if tag.contains("codex") { return Color(red: 1.0, green: 0.55, blue: 0.0) }
        return Self.claudeTagFg
    }

    /// Terminal tag color based on app type
    private var terminalTagColor: Color {
        if theme.isRetroArcade { return theme.terminalBadgeText }
        let tag = session.terminalTag.lowercased()
        if tag.contains("cmux") { return Color(red: 0.56, green: 0.79, blue: 0.98) }      // blue
        if tag.contains("ghostty") { return Color(red: 0.7, green: 0.6, blue: 1.0) }       // purple
        if tag.contains("zellij") { return Color(red: 0.3, green: 0.85, blue: 0.75) }     // teal
        if tag.contains("iterm") { return Color(red: 0.29, green: 0.87, blue: 0.5) }       // green
        if tag.contains("warp") { return Color(red: 0.96, green: 0.62, blue: 0.04) }       // amber
        if tag.contains("cursor") { return Color(red: 0.4, green: 0.91, blue: 0.98) }      // cyan
        if tag.contains("codex") { return Color(red: 1.0, green: 0.55, blue: 0.0) }        // orange
        if tag.contains("code") { return Color(red: 0.29, green: 0.67, blue: 0.96) }       // vs blue
        if tag.contains("kitty") { return Color(red: 0.94, green: 0.5, blue: 0.5) }        // salmon
        if tag.contains("claude") { return Self.claudeTagFg }                               // claude blue
        return theme.terminalBadgeText
    }

    private var agentBadgeFill: Color {
        theme.isRetroArcade ? theme.agentBadgeFill : agentTagColor.opacity(0.12)
    }

    private var terminalBadgeFill: Color {
        theme.isRetroArcade ? theme.terminalBadgeFill : terminalTagColor.opacity(0.12)
    }

    /// Accent color based on phase (used for status dot)
    private var accentColor: Color {
        if theme.isRetroArcade { return theme.primaryText }
        switch session.phase {
        case .processing, .compacting: return Self.cyanColor
        case .waitingForApproval, .waitingForQuestion: return Color(red: 0.96, green: 0.62, blue: 0.04) // amber
        case .waitingForInput: return Color(red: 0.29, green: 0.87, blue: 0.5)  // green
        case .idle, .ended: return theme.mutedText
        }
    }

    /// Title text: "projectName · displayTitle" or just projectName if same
    private var titleText: String {
        let display = session.displayTitle
        if display == session.projectName {
            return session.projectName
        }
        return "\(session.projectName) \u{00B7} \(display)"
    }

    private var previewPrefixColor: Color {
        theme.primaryText.opacity(theme.isRetroArcade ? 1.0 : 0.82)
    }

    private var previewBodyColor: Color {
        theme.secondaryText.opacity(theme.isRetroArcade ? 1.0 : 0.74)
    }

    private var previewMutedColor: Color {
        theme.secondaryText.opacity(theme.isRetroArcade ? 0.9 : 0.62)
    }

    @ObservedObject private var buddyReader = BuddyReader.shared
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    @AppStorage("usePixelCat") private var usePixelCat: Bool = false
    @State private var phaseFlash = false
    @State private var previousPhase: SessionPhase?
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    /// Whether the pending tool is AskUserQuestion with options
    private var askUserOptions: [QuestionOption]? {
        guard let toolName = session.pendingToolName, toolName == "AskUserQuestion",
              let input = session.activePermission?.toolInput,
              let questionsValue = input["questions"]?.value as? [[String: Any]] else { return nil }
        var options: [QuestionOption] = []
        for q in questionsValue {
            if let opts = q["options"] as? [[String: Any]] {
                for opt in opts {
                    let label = opt["label"] as? String ?? ""
                    let desc = opt["description"] as? String
                    options.append(QuestionOption(label: label, description: desc))
                }
            }
        }
        return options.isEmpty ? nil : options
    }

    /// Animation state derived from session phase
    private var animationState: AnimationState {
        switch session.phase {
        case .processing, .compacting: return .working
        case .waitingForApproval, .waitingForQuestion: return .needsYou
        case .waitingForInput: return .done
        case .idle, .ended: return .idle
        }
    }

    /// Whether this session is active (not idle/ended)
    private var isActive: Bool {
        switch session.phase {
        case .processing, .compacting, .waitingForApproval, .waitingForQuestion, .waitingForInput:
            return true
        case .idle, .ended:
            return false
        }
    }

    /// Whether this session has ended
    private var isEnded: Bool { session.phase == .ended }

    private var iconScale: CGFloat { isActive ? 0.45 : 0.35 }
    private var iconSize: CGFloat { isActive ? 28 : 22 }
    private var titleFontSize: CGFloat { isActive ? 13 : 11 }
    private var subtitleFontSize: CGFloat { isActive ? 10 : 9 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: isActive ? 8 : 6) {
                // Buddy icon or pixel cat
                ZStack {
                    if usePixelCat {
                        PixelCharacterView(state: animationState)
                            .scaleEffect(iconScale)
                    } else if let buddy = buddyReader.buddy {
                        EmojiPixelView(emoji: buddy.species.emoji, style: .rock)
                            .scaleEffect(iconScale)
                    } else {
                        PixelCharacterView(state: animationState)
                            .scaleEffect(iconScale)
                    }
                    // Status dot overlay
                    Circle()
                        .fill(accentColor)
                        .frame(width: isActive ? 6 : 5, height: isActive ? 6 : 5)
                        .shadow(color: accentColor.opacity(0.6), radius: isActive ? 3 : 2)
                        .offset(x: iconSize / 2 - 3, y: iconSize / 2 - 3)
                }
                .frame(width: iconSize, height: iconSize)
                .padding(.top, 2)

                // Content
                VStack(alignment: .leading, spacing: isActive ? 4 : 3) {
                    // Title row
                    HStack(spacing: 4) {
                        Text(titleText)
                            .notchFont(titleFontSize, weight: isActive ? .semibold : .medium)
                            .foregroundColor(theme.primaryText)
                            .opacity(isActive ? 0.95 : 0.85)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        sessionIdentityCluster

                        // Subagent badge (if active)
                        if session.subagentState.hasActiveSubagent {
                            Text("⚡\(session.subagentState.activeTasks.count)")
                                .notchFont(8, weight: .medium)
                                .foregroundColor(Color(red: 0.6, green: 0.8, blue: 1.0))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color(red: 0.6, green: 0.8, blue: 1.0).opacity(0.12))
                                )
                        }

                        // Ended tag
                        if isEnded {
                            Text(L10n.ended)
                                .notchFont(8, weight: .semibold)
                                .notchSecondaryForeground()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.subduedBadgeFill))
                        }

                        // Duration — colored when active, otherwise inherits palette fg
                        Text(durationText)
                            .notchFont(10, weight: isActive ? .medium : .regular)
                            .foregroundColor(isActive ? accentColor.opacity(theme.isRetroArcade ? 1.0 : 0.7) : theme.secondaryText)
                            .opacity(isActive ? 1.0 : 0.3)

                        // Delete button (always visible so users can dismiss stuck sessions)
                        Image(systemName: "xmark")
                            .notchFont(8, weight: .medium)
                            .notchSecondaryForeground()
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                            .onTapGesture { onArchive() }
                    }

                    // Subtitle
                    subtitleView

                    // Active session: show last tool action
                    if isActive, let toolName = session.lastToolName,
                       let lastMsg = session.lastMessage {
                        HStack(spacing: 3) {
                            Image(systemName: "wrench.and.screwdriver")
                                .notchFont(8)
                                .opacity(0.2)
                            Text("\(toolName): \(lastMsg)")
                                .notchFont(9)
                                .notchSecondaryForeground()
                                .lineLimit(1)
                        }
                    }

                    // AskUserQuestion: show options inline
                    if isWaitingForApproval, let options = askUserOptions {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.claudeNeedsInput)
                                .notchFont(9)
                                .foregroundColor(theme.needsYouColor)

                            HStack(spacing: 6) {
                                ForEach(Array(options.prefix(3).enumerated()), id: \.offset) { index, option in
                                    Text(option.label)
                                        .notchFont(9, weight: .medium)
                                        .foregroundColor(theme.primaryText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(theme.needsYouColor.opacity(0.15))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .strokeBorder(theme.needsYouColor.opacity(0.25), lineWidth: 0.5)
                                                )
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            DebugLogger.log("AskUser", "Option \(index + 1) tapped: \(option.label)")
                                            Task {
                                                await sendOptionToTerminal(index: index + 1, session: session)
                                            }
                                        }
                                }

                                Image(systemName: "terminal")
                                    .notchFont(9)
                                    .foregroundColor(theme.needsYouColor.opacity(0.75))
                                    .frame(width: 20, height: 20)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(theme.needsYouColor.opacity(0.1))
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture { onFocus() }
                            }
                        }
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    // Regular approval buttons
                    else if isWaitingForApproval {
                        InlineApprovalButtons(
                            onChat: onChat,
                            onApprove: onApprove,
                            onReject: onReject
                        )
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, isActive ? 10 : 7)
            .contentShape(Rectangle())
            .onTapGesture { onChat() }
            .background(
                ZStack {
                    // Base background
                    RoundedRectangle(cornerRadius: isActive ? 8 : 6)
                        .fill(isActive
                            ? accentColor.opacity(isHovered ? 0.1 : 0.05)
                            : (isHovered ? theme.overlay.opacity(0.18) : Color.clear))

                    // Phase transition flash
                    if phaseFlash {
                        RoundedRectangle(cornerRadius: isActive ? 8 : 6)
                            .fill(accentColor.opacity(0.15))
                            .transition(.opacity)
                    }
                }
            )
            .onChange(of: session.phase) { oldPhase, newPhase in
                // Visual flash on any phase change. Keep this on phase
                // because flashing mirrors subjective activity (including
                // transient errors). Sound is handled separately below.
                if oldPhase != newPhase {
                    withAnimation(.easeIn(duration: 0.15)) {
                        phaseFlash = true
                    }
                    withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                        phaseFlash = false
                    }
                }
            }
            .onChange(of: session.lastStopAt) { oldStop, newStop in
                // Play completion sound ONLY on a real Stop hook.
                // `lastStopAt` is set exclusively in SessionStore's Stop-
                // event handler (with a 3 s dedup window for retry
                // cascades). Phase-based detection used to fire here but
                // it mistakes `Notification status=waiting_for_input`
                // (network error / idle-prompt) for a completion, which
                // caused old already-finished sessions to replay the sound
                // whenever the network flapped.
                guard let new = newStop else { return }
                if let old = oldStop, old >= new { return }
                SoundManager.shared.play(.sessionComplete)
            }
        }
        .onHover { isHovered = $0 }
        .opacity(isEnded ? 0.4 : 1.0)
    }

    @ViewBuilder
    private var sessionIdentityCluster: some View {
        HStack(spacing: 6) {
            identityChip(
                symbol: session.agentIconSymbolName,
                label: session.agentTag,
                foreground: agentTagColor,
                background: agentBadgeFill,
                action: nil
            )

            identityChip(
                symbol: session.terminalIconSymbolName,
                label: session.isGraphicalTerminalSurface ? nil : session.terminalTag,
                foreground: terminalTagColor,
                background: terminalBadgeFill,
                action: isEnded ? nil : onFocus
            )
        }
    }

    private func identityChip(
        symbol: String,
        label: String?,
        foreground: Color,
        background: Color,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: label == nil ? 0 : 4) {
            Image(systemName: symbol)
                .notchFont(8, weight: .semibold)
            if let label, !label.isEmpty {
                Text(label)
                    .notchFont(8, weight: .semibold)
                    .lineLimit(1)
            }
        }
        .foregroundColor(foreground)
        .padding(.horizontal, label == nil ? 6 : 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(background))
        .contentShape(Rectangle())
        .onTapGesture {
            action?()
        }
    }

    // MARK: - AskUserQuestion Response

    /// Send an option selection to the session's terminal
    private func sendOptionToTerminal(index: Int, session: SessionState) async {
        // Unified relay — TerminalWriter covers cmux (precise target),
        // iTerm2, Ghostty and Terminal.app, all with hard timeouts. The old
        // bespoke ladder here only knew iTerm/Terminal/cmux, so option taps
        // did nothing for Ghostty/Warp/… users without cmux (issue #44).
        if await TerminalWriter.shared.sendText("\(index)", to: session) {
            DebugLogger.log("AskUser", "Sent option \(index) via TerminalWriter")
            return
        }

        // Couldn't inject the keystroke — at least bring the terminal
        // forward so the user can answer by hand.
        DebugLogger.log("AskUser", "No supported terminal, jumping")
        await TerminalJumper.shared.jump(to: session)
    }

    // MARK: - Subtitle

    @ViewBuilder
    private var subtitleView: some View {
        if isWaitingForApproval, let toolName = session.pendingToolName {
            // Approval state: show tool info as subtitle
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    Text(L10n.you)
                        .notchFont(9)
                        .notchSecondaryForeground()
                    Text(MCPToolFormatter.formatToolName(toolName))
                        .notchFont(9)
                        .opacity(0.55)
                        .lineLimit(1)
                }
                HStack(spacing: 2) {
                    Text("AI ")
                        .notchFont(9, weight: .medium)
                        .foregroundColor(previewPrefixColor)
                    if isInteractiveTool {
                        Text(L10n.needsInput)
                            .notchFont(9)
                            .foregroundColor(previewBodyColor)
                            .lineLimit(1)
                    } else if let input = session.pendingToolInput {
                        Text(input)
                            .notchFont(9)
                            .foregroundColor(previewBodyColor)
                            .lineLimit(1)
                    }
                }
            }
        } else if let summary = session.smartSummary {
            // Smart summary with role prefixes
            VStack(alignment: .leading, spacing: 1) {
                let parts = summary.components(separatedBy: "\n")
                if parts.count >= 2 {
                    // Line 1: user question
                    HStack(spacing: 0) {
                        Text(L10n.you)
                            .notchFont(9)
                            .notchSecondaryForeground()
                        Text(parts[0])
                            .notchFont(9)
                            .foregroundColor(previewMutedColor)
                            .lineLimit(1)
                    }
                    // Line 2: AI reply
                    HStack(spacing: 0) {
                        Text("AI ")
                            .notchFont(9, weight: .medium)
                            .foregroundColor(previewPrefixColor)
                        Text(parts[1])
                            .notchFont(9)
                            .foregroundColor(previewBodyColor)
                            .lineLimit(1)
                    }
                } else {
                    // Single line summary — show as AI line
                    HStack(spacing: 0) {
                        Text("AI ")
                            .notchFont(9, weight: .medium)
                            .foregroundColor(previewPrefixColor)
                        Text(summary)
                            .notchFont(9)
                            .foregroundColor(previewBodyColor)
                            .lineLimit(1)
                    }
                }
            }
        } else if let role = session.lastMessageRole {
            // Fallback: show last message with role prefix
            VStack(alignment: .leading, spacing: 1) {
                switch role {
                case "user":
                    HStack(spacing: 0) {
                        Text(L10n.you)
                            .notchFont(9)
                            .notchSecondaryForeground()
                        if let msg = session.lastMessage {
                            Text(msg)
                                .notchFont(9)
                                .foregroundColor(previewMutedColor)
                                .lineLimit(1)
                        }
                    }
                case "tool":
                    HStack(spacing: 0) {
                        Text("AI ")
                            .notchFont(9, weight: .medium)
                            .foregroundColor(previewPrefixColor)
                        if let toolName = session.lastToolName {
                            Text(MCPToolFormatter.formatToolName(toolName))
                                .notchFont(9)
                                .foregroundColor(previewBodyColor)
                                .lineLimit(1)
                        }
                    }
                default:
                    HStack(spacing: 0) {
                        Text("AI ")
                            .notchFont(9, weight: .medium)
                            .foregroundColor(previewPrefixColor)
                        if let msg = session.lastMessage {
                            Text(msg)
                                .notchFont(9)
                                .foregroundColor(previewBodyColor)
                                .lineLimit(1)
                        }
                    }
                }
            }
        } else if let lastMsg = session.lastMessage {
            HStack(spacing: 0) {
                Text("AI ")
                    .notchFont(9, weight: .medium)
                    .foregroundColor(previewPrefixColor)
                Text(lastMsg)
                    .notchFont(9)
                    .foregroundColor(previewBodyColor)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Project Group Header

struct ProjectGroupHeader: View {
    let group: ProjectGroup
    let isCollapsed: Bool
    let onToggle: () -> Void
    let onMoveRequested: () -> Void

    @State private var isHovered = false
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .notchFont(11, weight: .semibold)
                .notchSecondaryForeground()
                .frame(width: 12)

            Text(group.name)
                .notchFont(13, weight: .semibold)
                .opacity(0.8)

            if group.activeCount > 0 {
                Text("\(group.activeCount) \(L10n.active)")
                    .notchFont(11, weight: .medium)
                    .notchSecondaryForeground()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.overlay.opacity(0.24))
                    )
            } else if group.isArchivable {
                Text(L10n.archived)
                    .notchFont(11, weight: .medium)
                    .notchSecondaryForeground()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.overlay.opacity(0.18))
                    )
            }

            Spacer()

            // Hide-this-group affordance (visible on hover).
            // Sibling Button (NOT nested inside the toggle's Button) so macOS
            // SwiftUI hit-testing routes the click here, not to the row toggle.
            if isHovered {
                Button {
                    onMoveRequested()
                } label: {
                    Image(systemName: "eye.slash")
                        .notchFont(11, weight: .medium)
                        .notchSecondaryForeground()
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(L10n.isChinese ? "移除此项目" : "Hide this project")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? theme.overlay.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                onMoveRequested()
            } label: {
                Label(L10n.isChinese ? "移除此项目" : "Hide this project",
                      systemImage: "eye.slash")
            }
        }
    }
}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text(L10n.deny)
                    .notchFont(11, weight: .medium)
                    .notchSecondaryForeground()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.overlay.opacity(0.24))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text(L10n.allow)
                    .notchFont(11, weight: .medium)
                    .foregroundColor(theme.inverseText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.primaryText.opacity(0.92))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .notchFont(12, weight: .medium)
                .opacity(isHovered ? 0.8 : 0.4)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? theme.overlay.opacity(0.24) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .notchFont(12, weight: .medium)
                Text(L10n.goToTerminal)
                    .notchFont(13, weight: .medium)
            }
            .opacity(isEnabled ? 0.9 : 0.3)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? theme.overlay.opacity(0.28) : theme.overlay.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .notchFont(12, weight: .medium)
                Text(L10n.terminal)
                    .notchFont(13, weight: .medium)
            }
            .foregroundColor(isEnabled ? theme.inverseText : nil)
            .opacity(isEnabled ? 1.0 : 0.4)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? theme.primaryText.opacity(0.95) : theme.overlay.opacity(0.18))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Subagent List View

struct SubagentListView: View {
    let session: SessionState
    @State private var isExpanded = true

    private static let agentColor = Color(red: 0.6, green: 0.8, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsible header
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Self.agentColor.opacity(0.15))
                    .frame(width: 1, height: 14)
                    .padding(.leading, 18)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .notchFont(7, weight: .medium)
                    .foregroundColor(Self.agentColor.opacity(0.4))

                Text("Subagents (\(session.subagentState.activeTasks.count))")
                    .notchFont(9, weight: .medium)
                    .foregroundColor(Self.agentColor.opacity(0.5))

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }
            .padding(.vertical, 3)

            if isExpanded {
                ForEach(Array(session.subagentState.activeTasks.values), id: \.taskToolId) { task in
                    HStack(spacing: 5) {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Self.agentColor.opacity(0.15))
                                .frame(width: 1)
                            Rectangle()
                                .fill(Self.agentColor.opacity(0.15))
                                .frame(width: 8, height: 1)
                        }
                        .frame(width: 12, height: 16)
                        .padding(.leading, 18)

                        Circle()
                            .fill(Self.agentColor.opacity(0.6))
                            .frame(width: 4, height: 4)

                        Text(task.description ?? "Agent")
                            .notchFont(9)
                            .opacity(0.45)
                            .lineLimit(1)

                        Spacer()

                        if !task.subagentTools.isEmpty {
                            Text("\(task.subagentTools.count) tools")
                                .notchFont(8)
                                .opacity(0.2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Usage Stats Bar

struct UsageStatsBar: View {
    @ObservedObject var monitor: RateLimitMonitor
    let totalMinutes: Int
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    @AppStorage("usageWarningThreshold") private var usageWarningThreshold: Int = 90
    @State private var appear = false
    @State private var pulsePhase = false
    @State private var justRefreshed = false

    private var maxPercent: Int {
        max(monitor.rateLimitInfo?.fiveHourPercent ?? 0,
            monitor.rateLimitInfo?.sevenDayPercent ?? 0)
    }

    /// Resolve the user's display mode preference, with auto-switching.
    /// `auto`: < 60% → compact, ≥ 60% → alert (pulses red ≥ 80%).
    private var effectiveMode: UsageBarDisplayMode {
        let pref = notchStore.customization.usageBarDisplayMode
        guard pref == .auto else { return pref }
        return maxPercent >= 60 ? .alert : .compact
    }

    private var shouldPulseFrame: Bool {
        effectiveMode == .alert && maxPercent >= 80
    }

    private func barColor(_ pct: Int) -> Color {
        let threshold = usageWarningThreshold
        if threshold > 0 && pct >= threshold { return theme.errorColor }
        if threshold > 0 && pct >= max(threshold - 20, 50) { return theme.needsYouColor }
        return theme.doneColor
    }

    private func formatTime(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }

    var body: some View {
        HStack(spacing: 0) {
            if let info = monitor.rateLimitInfo {
                Group {
                    switch effectiveMode {
                    // .tokens never reaches here (the unified TokenUsageStatsBar
                    // replaces this bar in tokens mode), but the switch must be
                    // exhaustive — fall back to compact defensively.
                    case .auto, .compact, .tokens: compactBody(info: info)
                    case .alert: alertBody(info: info)
                    case .time: timeBody(info: info)
                    }
                }
                refreshIndicator
            }
        }
        .padding(.horizontal, effectiveMode == .alert ? 10 : 8)
        .padding(.vertical, effectiveMode == .alert ? 5 : 4)
        .background(barBackground)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 5)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await refreshWithFeedback() }
        }
        .help(monitor.isLoading ? L10n.usageBarRefreshingHint
              : (justRefreshed ? L10n.usageBarJustRefreshed
                                : L10n.usageBarTapToRefresh))
        .animation(.easeInOut(duration: 0.3), value: effectiveMode)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                appear = true
            }
        }
    }

    @ViewBuilder
    private var barBackground: some View {
        if shouldPulseFrame {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.errorColor.opacity(pulsePhase ? 0.9 : 0.35), lineWidth: 1.2)
                )
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.overlay.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.usageBorder.opacity(0.7), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        if monitor.isLoading {
            Image(systemName: "arrow.triangle.2.circlepath")
                .notchFont(8)
                .foregroundColor(theme.mutedText)
                .rotationEffect(.degrees(pulsePhase ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: pulsePhase)
                .padding(.leading, 6)
        } else if justRefreshed {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .notchFont(8)
                Text(L10n.usageBarJustNow)
                    .notchFont(8, weight: .semibold)
            }
            .foregroundColor(theme.doneColor)
            .padding(.leading, 6)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private func refreshWithFeedback() async {
        await monitor.refresh()
        withAnimation(.easeOut(duration: 0.25)) {
            justRefreshed = true
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        withAnimation(.easeIn(duration: 0.4)) {
            justRefreshed = false
        }
    }

    // MARK: - Mode renderers

    @ViewBuilder
    private func compactBody(info: RateLimitDisplayInfo) -> some View {
        HStack(spacing: 6) {
            usageGaugeCompact(pct: info.fiveHourPercent ?? 0, label: "5h", resetAt: info.fiveHourResetAt)
            if let sevenDay = info.sevenDayPercent, sevenDay > 0 {
                usageGaugeCompact(pct: sevenDay, label: "7d", resetAt: info.sevenDayResetAt)
            }
            Rectangle()
                .fill(theme.usageBorder.opacity(0.8))
                .frame(width: 1, height: 14)
            if totalMinutes > 0 {
                Text(formatTime(totalMinutes))
                    .notchFont(8, weight: .regular, design: .monospaced)
                    .notchSecondaryForeground()
            }
        }
    }

    @ViewBuilder
    private func alertBody(info: RateLimitDisplayInfo) -> some View {
        // Vertical stack — horizontal layout collided when two gauges shared
        // a single row inside the notch's constrained width (5h's percentage
        // overlapped 7d's). Per-row layout keeps both gauges readable and
        // aligns label / percentage / bar columns across both rows.
        VStack(alignment: .leading, spacing: 3) {
            usageGaugeAlert(pct: info.fiveHourPercent ?? 0, label: "5h", resetAt: info.fiveHourResetAt)
            if let sevenDay = info.sevenDayPercent, sevenDay > 0 {
                usageGaugeAlert(pct: sevenDay, label: "7d", resetAt: info.sevenDayResetAt)
            }
        }
    }

    @ViewBuilder
    private func timeBody(info: RateLimitDisplayInfo) -> some View {
        HStack(spacing: 10) {
            usageGaugeTime(pct: info.fiveHourPercent ?? 0, label: "5h", resetAt: info.fiveHourResetAt)
            if let sevenDay = info.sevenDayPercent {
                Rectangle()
                    .fill(theme.usageBorder.opacity(0.4))
                    .frame(width: 1, height: 22)
                usageGaugeTime(pct: sevenDay, label: "7d", resetAt: info.sevenDayResetAt)
            }
        }
    }

    private func shouldBlink(_ pct: Int) -> Bool {
        usageWarningThreshold > 0 && pct >= usageWarningThreshold
    }

    @ViewBuilder
    private func usageGaugeCompact(pct: Int, label: String, resetAt: Date?) -> some View {
        let color = barColor(pct)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label)
                    .notchFont(7, weight: .bold)
                    .notchSecondaryForeground()
                Text("\(pct)%")
                    .notchFont(9, weight: .semibold, design: .monospaced)
                    .foregroundColor(color)
                    .opacity(shouldBlink(pct) ? (pulsePhase ? 1.0 : 0.3) : 1.0)
                if let resetAt, resetAt.timeIntervalSinceNow > 0 {
                    Text(formatResetShort(resetAt.timeIntervalSinceNow))
                        .notchFont(7)
                        .foregroundColor(theme.usageText)
                        .opacity(0.45)
                }
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.usageTrack.opacity(0.85))
                    .frame(width: 50, height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, 50 * CGFloat(pct) / 100), height: 3)
                    .shadow(color: color.opacity(0.4), radius: 2)
            }
        }
        .help(usageTooltip(pct: pct, label: label, resetAt: resetAt))
    }

    @ViewBuilder
    private func usageGaugeAlert(pct: Int, label: String, resetAt: Date?) -> some View {
        let color = barColor(pct)
        // Single-row layout: LABEL | PERCENTAGE | BAR | RESET-HINT
        // Fixed widths on label/percentage so multiple rows line up vertically
        // when stacked. Previous horizontal-stack-of-gauges design overflowed
        // the notch width and percentages overlapped each other.
        HStack(spacing: 5) {
            Text(label.uppercased())
                .notchFont(8, weight: .semibold)
                .foregroundColor(theme.mutedText)
                .tracking(0.4)
                .frame(width: 18, alignment: .leading)
            Text("\(pct)%")
                .notchFont(13, weight: .bold, design: .monospaced)
                .foregroundColor(color)
                .opacity(shouldBlink(pct) ? (pulsePhase ? 1.0 : 0.4) : 1.0)
                .shadow(color: color.opacity(shouldBlink(pct) ? 0.7 : 0), radius: 4)
                .frame(width: 38, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.usageTrack.opacity(0.85))
                    .frame(width: 60, height: 5)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(2, 60 * CGFloat(pct) / 100), height: 5)
                    .shadow(color: color.opacity(0.65), radius: 3)
            }
            if let resetAt, resetAt.timeIntervalSinceNow > 0 {
                Text(formatResetShort(resetAt.timeIntervalSinceNow))
                    .notchFont(7)
                    .foregroundColor(theme.usageText)
                    .opacity(0.55)
                    .frame(minWidth: 32, alignment: .leading)
            }
        }
        .help(usageTooltip(pct: pct, label: label, resetAt: resetAt))
    }

    @ViewBuilder
    private func usageGaugeTime(pct: Int, label: String, resetAt: Date?) -> some View {
        let color = barColor(pct)
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(theme.usageTrack.opacity(0.85), lineWidth: 2)
                    .frame(width: 22, height: 22)
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(pct) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(-90))
                Text("\(pct)%")
                    .notchFont(7, weight: .semibold, design: .monospaced)
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let resetAt, resetAt.timeIntervalSinceNow > 0 {
                    Text(formatResetShort(resetAt.timeIntervalSinceNow))
                        .notchFont(11, weight: .semibold, design: .monospaced)
                        .foregroundColor(theme.usageText)
                } else {
                    Text("--")
                        .notchFont(11, weight: .semibold, design: .monospaced)
                        .foregroundColor(theme.mutedText)
                }
                Text(label == "7d" ? L10n.usageBarTimeUntil7d : L10n.usageBarTimeUntil5h)
                    .notchFont(7)
                    .foregroundColor(theme.mutedText)
            }
        }
        .help(usageTooltip(pct: pct, label: label, resetAt: resetAt))
    }

    private func formatResetShort(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 {
            let h = Int(seconds / 3600)
            let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(Int(seconds / 86400))d"
    }

    private func usageTooltip(pct: Int, label: String, resetAt: Date?) -> String {
        let window = label == "7d" ? "7天" : "5小时"
        guard let resetAt = resetAt else { return "\(window)窗口: \(pct)%" }
        let remaining = resetAt.timeIntervalSinceNow
        if remaining <= 0 { return "\(window)窗口: \(pct)% (已重置)" }
        let timeStr: String
        if remaining < 3600 {
            timeStr = "\(Int(remaining / 60))分钟"
        } else if remaining < 86400 {
            let h = Int(remaining / 3600)
            let m = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            timeStr = m > 0 ? "\(h)小时\(m)分钟" : "\(h)小时"
        } else {
            timeStr = "\(Int(remaining / 86400))天"
        }
        return "\(window)窗口: \(pct)% (\(timeStr)后重置)"
    }
}

// MARK: - Codex Usage Stats Bar

struct CodexUsageStatsBar: View {
    @ObservedObject var monitor: CodexUsageMonitor
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    @AppStorage("usageWarningThreshold") private var usageWarningThreshold: Int = 90
    @State private var appear = false
    @State private var pulsePhase = false
    @State private var justRefreshed = false

    private var maxPercent: Int {
        monitor.snapshot?.windows.map { $0.roundedUsedPercentage }.max() ?? 0
    }

    private var effectiveMode: UsageBarDisplayMode {
        let pref = notchStore.customization.usageBarDisplayMode
        guard pref == .auto else { return pref }
        return maxPercent >= 60 ? .alert : .compact
    }

    /// The per-window gauges (weekly quota etc.), rendered per display mode.
    /// Extracted so the body can branch cleanly between window / unlimited /
    /// credit plans (Codex dropped the 5h window — now weekly-only, or
    /// credit/unlimited-based depending on plan).
    @ViewBuilder
    private func windowGauges(_ snapshot: CodexUsageSnapshot) -> some View {
        switch effectiveMode {
        // .tokens handled by the unified bar; fall back to compact.
        case .auto, .compact, .tokens:
            HStack(spacing: 6) {
                ForEach(snapshot.windows) { window in
                    usageGaugeCompact(pct: window.roundedUsedPercentage, label: window.label, resetAt: window.resetsAt)
                }
            }
        case .alert:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(snapshot.windows) { window in
                    usageGaugeAlert(pct: window.roundedUsedPercentage, label: window.label, resetAt: window.resetsAt)
                }
            }
        case .time:
            HStack(spacing: 10) {
                ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { idx, window in
                    if idx > 0 {
                        Rectangle().fill(theme.usageBorder.opacity(0.4)).frame(width: 1, height: 22)
                    }
                    usageGaugeTime(pct: window.roundedUsedPercentage, label: window.label, resetAt: window.resetsAt)
                }
            }
        }
    }

    /// Unlimited plan — no cap, so a percentage gauge is meaningless.
    private var codexUnlimitedChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "infinity")
                .notchFont(11, weight: .bold)
                .foregroundColor(theme.doneColor)
            Text(L10n.codexUnlimited)
                .notchFont(9, weight: .semibold)
                .foregroundColor(theme.usageText)
        }
        .help("Codex: \(codexPlanName)\(L10n.codexUnlimited)")
    }

    /// Credit-based plan — show remaining balance instead of a window %.
    private func codexCreditsChip(balance: Double) -> some View {
        let shown = balance >= 1000 ? String(format: "%.1fK", balance / 1000) : String(format: "%.0f", balance)
        return HStack(spacing: 4) {
            Text(L10n.codexCreditsLabel)
                .notchFont(7, weight: .bold)
                .notchSecondaryForeground()
            Text(shown)
                .notchFont(10, weight: .semibold, design: .monospaced)
                .foregroundColor(theme.usageText)
        }
        .help("Codex: \(codexPlanName)\(L10n.codexCreditsLabel) \(shown)")
    }

    /// Plan-name prefix for tooltips, e.g. "GPT-5.3-Codex-Spark · ".
    /// Empty when the server didn't send limit_name.
    private var codexPlanName: String {
        guard let name = monitor.snapshot?.limitName, !name.isEmpty else { return "" }
        return "\(name) · "
    }

    private var shouldPulseFrame: Bool {
        effectiveMode == .alert && maxPercent >= 80
    }

    private func barColor(_ pct: Int) -> Color {
        let threshold = usageWarningThreshold
        if threshold > 0 && pct >= threshold { return theme.errorColor }
        if threshold > 0 && pct >= max(threshold - 20, 50) { return theme.needsYouColor }
        return theme.doneColor
    }

    var body: some View {
        HStack(spacing: 0) {
            if let snapshot = monitor.snapshot, !snapshot.isEmpty {
                HStack(spacing: 6) {
                    Text("Codex")
                        .notchFont(7, weight: .bold)
                        .notchSecondaryForeground()
                        .opacity(0.5)

                    Rectangle()
                        .fill(theme.usageBorder.opacity(0.8))
                        .frame(width: 1, height: effectiveMode == .alert ? 18 : 14)

                    Group {
                        // Post-5h-removal a Codex plan can be: window-based
                        // (weekly gauge), unlimited (∞), or credit-based.
                        if snapshot.isUnlimited {
                            codexUnlimitedChip
                        } else if !snapshot.windows.isEmpty {
                            windowGauges(snapshot)
                        } else if let balance = snapshot.creditBalance {
                            codexCreditsChip(balance: balance)
                        }
                    }
                }
                refreshIndicator
            }
        }
        .padding(.horizontal, effectiveMode == .alert ? 10 : 8)
        .padding(.vertical, effectiveMode == .alert ? 5 : 4)
        .background(barBackground)
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 5)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await refreshWithFeedback() }
        }
        .help(monitor.isLoading ? L10n.usageBarRefreshingHint
              : (justRefreshed ? L10n.usageBarJustRefreshed
                                : L10n.usageBarTapToRefresh))
        .animation(.easeInOut(duration: 0.3), value: effectiveMode)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                appear = true
            }
        }
    }

    @ViewBuilder
    private var barBackground: some View {
        if shouldPulseFrame {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.errorColor.opacity(pulsePhase ? 0.9 : 0.35), lineWidth: 1.2)
                )
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.overlay.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.usageBorder.opacity(0.7), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        if monitor.isLoading {
            Image(systemName: "arrow.triangle.2.circlepath")
                .notchFont(8)
                .foregroundColor(theme.mutedText)
                .rotationEffect(.degrees(pulsePhase ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: pulsePhase)
                .padding(.leading, 6)
        } else if justRefreshed {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .notchFont(8)
                Text(L10n.usageBarJustNow)
                    .notchFont(8, weight: .semibold)
            }
            .foregroundColor(theme.doneColor)
            .padding(.leading, 6)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private func refreshWithFeedback() async {
        await monitor.refresh()
        withAnimation(.easeOut(duration: 0.25)) {
            justRefreshed = true
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        withAnimation(.easeIn(duration: 0.4)) {
            justRefreshed = false
        }
    }

    private func shouldBlink(_ pct: Int) -> Bool {
        usageWarningThreshold > 0 && pct >= usageWarningThreshold
    }

    @ViewBuilder
    private func usageGaugeCompact(pct: Int, label: String, resetAt: Date?) -> some View {
        let color = barColor(pct)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label)
                    .notchFont(7, weight: .bold)
                    .notchSecondaryForeground()
                Text("\(pct)%")
                    .notchFont(9, weight: .semibold, design: .monospaced)
                    .foregroundColor(color)
                    .opacity(shouldBlink(pct) ? (pulsePhase ? 1.0 : 0.3) : 1.0)
                if let resetAt, resetAt.timeIntervalSinceNow > 0 {
                    Text(formatResetShort(resetAt.timeIntervalSinceNow))
                        .notchFont(7)
                        .foregroundColor(theme.usageText)
                        .opacity(0.45)
                }
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.usageTrack.opacity(0.85))
                    .frame(width: 50, height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(2, 50 * CGFloat(pct) / 100), height: 3)
                    .shadow(color: color.opacity(0.4), radius: 2)
            }
        }
        .help(usageTooltip(pct: pct, label: label, resetAt: resetAt))
    }

    @ViewBuilder
    private func usageGaugeAlert(pct: Int, label: String, resetAt: Date?) -> some View {
        let color = barColor(pct)
        // Single-row layout: LABEL | PERCENTAGE | BAR | RESET-HINT
        // Fixed widths on label/percentage so multiple rows line up vertically
        // when stacked. Previous horizontal-stack-of-gauges design overflowed
        // the notch width and percentages overlapped each other.
        HStack(spacing: 5) {
            Text(label.uppercased())
                .notchFont(8, weight: .semibold)
                .foregroundColor(theme.mutedText)
                .tracking(0.4)
                .frame(width: 18, alignment: .leading)
            Text("\(pct)%")
                .notchFont(13, weight: .bold, design: .monospaced)
                .foregroundColor(color)
                .opacity(shouldBlink(pct) ? (pulsePhase ? 1.0 : 0.4) : 1.0)
                .shadow(color: color.opacity(shouldBlink(pct) ? 0.7 : 0), radius: 4)
                .frame(width: 38, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.usageTrack.opacity(0.85))
                    .frame(width: 60, height: 5)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: max(2, 60 * CGFloat(pct) / 100), height: 5)
                    .shadow(color: color.opacity(0.65), radius: 3)
            }
            if let resetAt, resetAt.timeIntervalSinceNow > 0 {
                Text(formatResetShort(resetAt.timeIntervalSinceNow))
                    .notchFont(7)
                    .foregroundColor(theme.usageText)
                    .opacity(0.55)
                    .frame(minWidth: 32, alignment: .leading)
            }
        }
        .help(usageTooltip(pct: pct, label: label, resetAt: resetAt))
    }

    @ViewBuilder
    private func usageGaugeTime(pct: Int, label: String, resetAt: Date?) -> some View {
        let color = barColor(pct)
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(theme.usageTrack.opacity(0.85), lineWidth: 2)
                    .frame(width: 22, height: 22)
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(pct) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(-90))
                Text("\(pct)%")
                    .notchFont(7, weight: .semibold, design: .monospaced)
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let resetAt, resetAt.timeIntervalSinceNow > 0 {
                    Text(formatResetShort(resetAt.timeIntervalSinceNow))
                        .notchFont(11, weight: .semibold, design: .monospaced)
                        .foregroundColor(theme.usageText)
                } else {
                    Text("--")
                        .notchFont(11, weight: .semibold, design: .monospaced)
                        .foregroundColor(theme.mutedText)
                }
                Text(label)
                    .notchFont(7)
                    .foregroundColor(theme.mutedText)
            }
        }
        .help(usageTooltip(pct: pct, label: label, resetAt: resetAt))
    }

    private func formatResetShort(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 {
            let h = Int(seconds / 3600)
            let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(Int(seconds / 86400))d"
    }

    private func usageTooltip(pct: Int, label: String, resetAt: Date?) -> String {
        let prefix = "Codex: \(codexPlanName)"
        guard let resetAt else { return "\(prefix)\(label) \(pct)%" }
        let remaining = resetAt.timeIntervalSinceNow
        if remaining <= 0 { return "\(prefix)\(label) \(pct)% (reset)" }
        return "\(prefix)\(label) \(pct)% (resets in \(formatResetShort(remaining)))"
    }
}

// MARK: - Token Usage Stats Bar
//
// Unified, cross-model token meter (UsageBarDisplayMode.tokens). Reads today's
// actual token consumption from the local CLI transcripts via TokenUsageMonitor
// and replaces the per-provider plan-% bars when selected. Headline number is
// "billable" (input+output); cache tokens are shown muted because they are
// nearly free and would otherwise dwarf the real number (cache can be 100x+).

struct TokenUsageStatsBar: View {
    @ObservedObject var monitor: TokenUsageMonitor
    @ObservedObject private var notchStore: NotchCustomizationStore = .shared
    private var theme: ThemeResolver { ThemeResolver(theme: notchStore.customization.theme) }

    @State private var appear = false
    @State private var pulsePhase = false
    @State private var justRefreshed = false

    private func fmt(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: m >= 100 ? "%.0fM" : "%.1fM", m)
        }
        if n >= 1_000 {
            let k = Double(n) / 1_000
            return String(format: k >= 100 ? "%.0fK" : "%.1fK", k)
        }
        return "\(n)"
    }

    /// Compact, friendly model label. "claude-opus-4-8" → "Opus 4.8".
    /// Only trailing NUMERIC segments form the version, so a degenerate name
    /// like bare "opus" yields "Opus" (not "Opus opus").
    private func shortLabel(_ u: TokenModelUsage) -> String {
        let m = u.model.lowercased()
        func ver() -> String {
            // take trailing parts that look like version numbers (e.g. 4, 8)
            let digits = m.split(separator: "-").filter { $0.allSatisfy { $0.isNumber } }
            return digits.suffix(2).joined(separator: ".")
        }
        func labeled(_ family: String) -> String {
            let v = ver()
            return v.isEmpty ? family : "\(family) \(v)"
        }
        if m.contains("opus") { return labeled("Opus") }
        if m.contains("sonnet") { return labeled("Sonnet") }
        if m.contains("haiku") { return labeled("Haiku") }
        if u.provider == "Codex" { return "Codex" }
        return u.model
    }

    private var codexBlue: Color { Color(red: 0.56, green: 0.79, blue: 0.98) }

    var body: some View {
        HStack(spacing: 8) {
            if let snap = monitor.snapshot, !snap.isEmpty {
                // Headline: today's total billable.
                HStack(spacing: 4) {
                    Text(L10n.usageBarTokensToday)
                        .notchFont(7, weight: .semibold)
                        .foregroundColor(theme.mutedText)
                        .lineLimit(1)
                    Text(fmt(snap.totalBillable))
                        .notchFont(13, weight: .bold, design: .monospaced)
                        .foregroundColor(theme.doneColor)
                        .lineLimit(1)
                }
                Rectangle()
                    .fill(theme.usageBorder.opacity(0.5))
                    .frame(width: 1, height: 14)
                // Per-model billable, inline (no wrap). Same value size as the
                // headline so the numbers read consistently across the row.
                ForEach(snap.models.prefix(3)) { u in
                    HStack(spacing: 4) {
                        Text(shortLabel(u))
                            .notchFont(11, weight: .medium)
                            .foregroundColor(u.provider == "Codex" ? codexBlue : theme.usageText)
                            .lineLimit(1)
                        Text(fmt(u.billable))
                            .notchFont(13, weight: .semibold, design: .monospaced)
                            .foregroundColor(theme.usageText)
                            .lineLimit(1)
                    }
                }
                if snap.models.count > 3 {
                    Text(L10n.usageBarTokensMore(snap.models.count - 3))
                        .notchFont(7, weight: .regular)
                        .foregroundColor(theme.mutedText)
                        .opacity(0.5)
                        .lineLimit(1)
                }
                // Cache total, de-emphasized, at the end.
                Text(L10n.usageBarTokensCached(fmt(snap.totalCache)))
                    .notchFont(7, weight: .regular)
                    .foregroundColor(theme.usageText)
                    .opacity(0.45)
                    .lineLimit(1)
                refreshIndicator
            } else {
                Text(L10n.usageBarTokensEmpty)
                    .notchFont(8, weight: .regular)
                    .foregroundColor(theme.mutedText)
                    .opacity(0.6)
            }
        }
        .fixedSize(horizontal: true, vertical: false)   // single line, no wrap/compress
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.overlay.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.usageBorder.opacity(0.7), lineWidth: 0.5)
                )
        )
        .opacity(appear ? 1 : 0)
        .offset(y: appear ? 0 : 5)
        .contentShape(Rectangle())
        .onTapGesture { Task { await refreshWithFeedback() } }
        .help(monitor.isLoading ? L10n.usageBarRefreshingHint
              : (justRefreshed ? L10n.usageBarJustRefreshed : L10n.usageBarTapToRefresh))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsePhase = true
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                appear = true
            }
        }
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        if monitor.isLoading {
            Image(systemName: "arrow.triangle.2.circlepath")
                .notchFont(8, weight: .regular)
                .foregroundColor(theme.mutedText)
                .rotationEffect(.degrees(pulsePhase ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: pulsePhase)
                .padding(.leading, 6)
        } else if justRefreshed {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .notchFont(8, weight: .regular)
                Text(L10n.usageBarJustNow)
                    .notchFont(8, weight: .semibold)
            }
            .foregroundColor(theme.doneColor)
            .padding(.leading, 6)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private func refreshWithFeedback() async {
        await monitor.refresh()
        withAnimation(.easeOut(duration: 0.25)) { justRefreshed = true }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        withAnimation(.easeIn(duration: 0.4)) { justRefreshed = false }
    }
}
