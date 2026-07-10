//
//  HookDiagnosticsView.swift
//  ClaudeIsland
//
//  Advanced-tab panel that surfaces HookHealthCheck output and exposes
//  Reinstall / Uninstall / Auto-repair / Cleanup-legacy actions for both
//  Claude Code and Codex. No silent mutations — every button states what
//  it will do, and the whole view refreshes immediately after each action.
//

import SwiftUI

struct HookDiagnosticsView: View {
    @State private var claudeReport = HookHealthCheck.checkClaude()
    @State private var codexReport = HookHealthCheck.checkCodex()
    @State private var legacyCleanupMessage: String?
    @ObservedObject private var codexGate = CodexFeatureGate.shared
    private var theme: ThemeResolver {
        ThemeResolver(theme: NotchCustomizationStore.shared.customization.theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: L10n.hookDiagTitle) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.hookDiagSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    agentCard(
                        name: L10n.hookDiagAgentClaude,
                        icon: "brain",
                        report: claudeReport,
                        isEnabled: true,
                        onReinstall: reinstallClaude,
                        onUninstall: uninstallClaude
                    )

                    agentCard(
                        name: L10n.hookDiagAgentCodex,
                        icon: "chevron.left.forwardslash.chevron.right",
                        report: codexReport,
                        isEnabled: codexGate.isEnabled,
                        onReinstall: reinstallCodex,
                        onUninstall: uninstallCodex
                    )
                }
            }

            // Legacy cleanup — separate card so it's visible but not
            // confused with the per-agent actions above.
            SettingsCard(title: L10n.hookDiagCleanupLegacy) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.hookDiagCleanupLegacyHint)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        actionButton(
                            icon: "trash",
                            label: L10n.hookDiagCleanupLegacy,
                            action: runLegacyCleanup
                        )
                        Spacer()
                        if let msg = legacyCleanupMessage {
                            Text(msg)
                                .font(.system(size: 10))
                                .foregroundColor(theme.mutedText)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Per-agent card

    @ViewBuilder
    private func agentCard(
        name: String,
        icon: String,
        report: HookHealthReport,
        isEnabled: Bool,
        onReinstall: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 16)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                statusBadge(for: report, isEnabled: isEnabled)
            }

            if !isEnabled {
                Text(L10n.hookDiagCodexDisabledHint)
                    .font(.system(size: 10))
                    .foregroundColor(theme.mutedText)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !report.issues.isEmpty {
                issueList(report.issues)
            }

            if isEnabled {
                actionRow(report: report, onReinstall: onReinstall, onUninstall: onUninstall)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.overlay.opacity(0.14))
        )
    }

    private func statusBadge(for report: HookHealthReport, isEnabled: Bool) -> some View {
        let (text, color): (String, Color) = {
            if !isEnabled {
                return (L10n.hookDiagDisabled, theme.mutedText)
            }
            if report.isHealthy {
                if report.notices.isEmpty {
                    return (L10n.hookDiagHealthy, theme.doneColor)
                } else {
                    return (L10n.hookDiagNoticeCount(report.notices.count), theme.needsYouColor)
                }
            }
            return (L10n.hookDiagErrorCount(report.errors.count), theme.errorColor)
        }()

        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color.opacity(0.9))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    @ViewBuilder
    private func issueList(_ issues: [HookHealthReport.Issue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: issue.severity == .error ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 9))
                        .foregroundColor(issue.severity == .error ? theme.errorColor : theme.needsYouColor)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(localizedTitle(issue))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        if let detail = issueDetail(issue) {
                            Text(detail)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(theme.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private func actionRow(
        report: HookHealthReport,
        onReinstall: @escaping () -> Void,
        onUninstall: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            actionButton(icon: "arrow.clockwise", label: L10n.hookDiagRecheck, action: refresh)
            if !report.repairableIssues.isEmpty {
                actionButton(icon: "wand.and.stars", label: L10n.hookDiagRepair, action: onReinstall, prominent: true)
            }
            actionButton(icon: "arrow.triangle.2.circlepath", label: L10n.hookDiagReinstall, action: onReinstall)
            Spacer()
            actionButton(icon: "xmark", label: L10n.hookDiagUninstall, action: onUninstall, danger: true)
        }
        .padding(.leading, 24)
        .padding(.top, 2)
    }

    private func actionButton(
        icon: String,
        label: String,
        action: @escaping () -> Void,
        prominent: Bool = false,
        danger: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(prominent ? theme.inverseText : (danger ? theme.errorColor : theme.primaryText))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent
                          ? theme.doneColor
                          : theme.overlay.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                danger ? theme.errorColor.opacity(0.3) : theme.border.opacity(0.8),
                                lineWidth: 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func refresh() {
        claudeReport = HookHealthCheck.checkClaude()
        codexReport = HookHealthCheck.checkCodex()
    }

    private func reinstallClaude() {
        HookInstaller.userDisabled = false
        HookInstaller.uninstall()
        HookInstaller.installIfNeeded()
        refresh()
    }

    private func uninstallClaude() {
        // Explicit user opt-out — stop launch install / auto-heal from
        // re-adding the hooks behind their back.
        HookInstaller.userDisabled = true
        HookInstaller.uninstall()
        refresh()
    }

    private func reinstallCodex() {
        CodexHookInstaller.uninstall()
        CodexHookInstaller.installIfNeeded()
        refresh()
    }

    private func uninstallCodex() {
        CodexHookInstaller.uninstall()
        refresh()
    }

    private func runLegacyCleanup() {
        // Detect whether anything existed before the call, so we can report
        // "cleaned" vs "nothing to clean" without a dedicated return value.
        let hooksDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/hooks")
        let hadLegacyFile = HookInstaller.legacyHookScripts.contains { name in
            FileManager.default.fileExists(
                atPath: hooksDir.appendingPathComponent(name).path
            )
        }
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let hadLegacyRef: Bool = {
            guard let data = try? Data(contentsOf: settings),
                  let str = String(data: data, encoding: .utf8) else { return false }
            return HookInstaller.legacyHookScripts.contains { str.contains($0) }
        }()

        HookInstaller.cleanupLegacyHooks()
        refresh()

        withAnimation {
            legacyCleanupMessage = (hadLegacyFile || hadLegacyRef)
                ? L10n.hookDiagCleanupDone
                : L10n.hookDiagNothingToClean
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { legacyCleanupMessage = nil }
        }
    }

    // MARK: - Issue localization

    private func localizedTitle(_ issue: HookHealthReport.Issue) -> String {
        switch issue {
        case .scriptMissing:
            return L10n.hookDiagIssueScriptMissing
        case .scriptNotExecutable:
            return L10n.hookDiagIssueScriptNotExecutable
        case .configMalformedJSON:
            return L10n.hookDiagIssueConfigMalformed
        case .staleCommandPath:
            return L10n.hookDiagIssueStaleCommand
        case .otherHooksDetected:
            return L10n.hookDiagIssueOtherHooks
        case .manifestMissing:
            return L10n.hookDiagIssueManifestMissing
        }
    }

    private func issueDetail(_ issue: HookHealthReport.Issue) -> String? {
        switch issue {
        case .scriptMissing(let path),
             .scriptNotExecutable(let path),
             .configMalformedJSON(let path),
             .manifestMissing(let path):
            return path
        case .staleCommandPath(let recorded, _):
            return recorded
        case .otherHooksDetected(let names):
            return names.joined(separator: ", ")
        }
    }
}
