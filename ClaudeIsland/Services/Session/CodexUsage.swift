//
//  CodexUsage.swift
//  ClaudeIsland
//
//  Reads rate-limit / usage data from Codex rollout JSONL files.
//  Scans ~/.codex/sessions/rollout-*.jsonl for the most recent token_count event.
//

import Combine
import Foundation

struct CodexUsageWindow: Equatable, Codable, Sendable, Identifiable {
    var key: String
    var label: String
    var usedPercentage: Double
    var leftPercentage: Double
    var windowMinutes: Int
    var resetsAt: Date?

    var id: String { key }

    var roundedUsedPercentage: Int {
        Int(usedPercentage.rounded())
    }
}

struct CodexUsageSnapshot: Equatable, Codable, Sendable {
    var sourceFilePath: String
    var capturedAt: Date?
    var planType: String?
    /// Human plan/limit name from `rate_limits.limit_name`, e.g.
    /// "GPT-5.3-Codex-Spark". `plan_type` went null after Codex dropped
    /// the 5h window, so this is now the only plan label available.
    var limitName: String?
    var limitID: String?
    var windows: [CodexUsageWindow]
    /// `rate_limits.credits.unlimited` — plan has no cap. Show "∞" rather
    /// than a meaningless 0% gauge.
    var isUnlimited: Bool
    /// `rate_limits.credits.balance`, only when `has_credits` is true.
    /// nil for window-based plans (e.g. Spark) where credits are absent.
    var creditBalance: Double?

    /// Nothing worth drawing: no usage windows AND no unlimited flag AND
    /// no credit balance. (Post-5h-removal a plan can legitimately have a
    /// single weekly window, or be credit/unlimited-based with none.)
    var isEmpty: Bool { windows.isEmpty && !isUnlimited && creditBalance == nil }
}

// MARK: - Usage Monitor

/// Periodically loads the latest Codex usage snapshot and publishes it for UI consumption.
/// Mirrors the interface of RateLimitMonitor.
@MainActor
class CodexUsageMonitor: ObservableObject {
    static let shared = CodexUsageMonitor()

    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var isLoading = false

    private var refreshTimer: Timer?

    private init() {}

    func start() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        snapshot = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        snapshot = try? CodexUsageLoader.load()
    }
}

// MARK: - Usage Loader

enum CodexUsageLoader {
    static let defaultRootURL: URL = ConfigPaths.codexDir.appendingPathComponent("sessions", isDirectory: true)

    private struct Candidate {
        var fileURL: URL
        var modifiedAt: Date
    }

    static func load(
        fromRootURL rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default
    ) throws -> CodexUsageSnapshot? {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return nil }

        var candidates: [Candidate] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl",
                  let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  resourceValues.isRegularFile == true else { continue }
            candidates.append(Candidate(
                fileURL: fileURL,
                modifiedAt: resourceValues.contentModificationDate ?? .distantPast
            ))
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            lhs.modifiedAt == rhs.modifiedAt
                ? lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedDescending
                : lhs.modifiedAt > rhs.modifiedAt
        }

        for candidate in sortedCandidates {
            if let snapshot = loadLatestSnapshot(from: candidate.fileURL, modifiedAt: candidate.modifiedAt) {
                return snapshot
            }
        }

        return nil
    }

    private static func loadLatestSnapshot(from fileURL: URL, modifiedAt: Date) -> CodexUsageSnapshot? {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        var latestSnapshot: CodexUsageSnapshot?
        contents.enumerateLines { line, _ in
            guard let snapshot = snapshot(from: line, filePath: fileURL.path, fallbackTimestamp: modifiedAt) else {
                return
            }
            latestSnapshot = snapshot
        }
        return latestSnapshot
    }

    private static func snapshot(from line: String, filePath: String, fallbackTimestamp: Date) -> CodexUsageSnapshot? {
        guard let object = jsonObject(for: line),
              object["type"] as? String == "event_msg" else { return nil }

        let payload = object["payload"] as? [String: Any] ?? [:]
        guard payload["type"] as? String == "token_count",
              let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }

        let windows = ["primary", "secondary"].compactMap { key in
            usageWindow(for: key, in: rateLimits)
        }

        // Credits block appeared alongside the 5h-window removal. For
        // window-based plans (Spark) it's all-false/empty; for credit or
        // unlimited plans it carries the real quota signal.
        let credits = rateLimits["credits"] as? [String: Any]
        let isUnlimited = bool(from: credits?["unlimited"]) ?? false
        let hasCredits = bool(from: credits?["has_credits"]) ?? false
        let creditBalance = hasCredits ? number(from: credits?["balance"]) : nil

        // Keep the snapshot if it carries ANY signal — windows, unlimited,
        // or a credit balance. Previously required a non-empty window, which
        // dropped unlimited/credit-only plans entirely.
        guard !windows.isEmpty || isUnlimited || creditBalance != nil else { return nil }

        return CodexUsageSnapshot(
            sourceFilePath: filePath,
            capturedAt: timestamp(from: object["timestamp"]) ?? fallbackTimestamp,
            planType: string(from: rateLimits["plan_type"]),
            limitName: string(from: rateLimits["limit_name"]),
            limitID: string(from: rateLimits["limit_id"]),
            windows: windows,
            isUnlimited: isUnlimited,
            creditBalance: creditBalance
        )
    }

    private static func usageWindow(for key: String, in rateLimits: [String: Any]) -> CodexUsageWindow? {
        // `secondary` is JSON null after the 5h removal — the cast fails and
        // we skip it (not an error). A zero/negative window is meaningless.
        guard let payload = rateLimits[key] as? [String: Any],
              let usedPercentage = number(from: payload["used_percent"]),
              let windowMinutes = integer(from: payload["window_minutes"]),
              windowMinutes > 0 else { return nil }

        return CodexUsageWindow(
            key: key,
            label: windowLabel(forMinutes: windowMinutes),
            usedPercentage: usedPercentage,
            leftPercentage: max(0, 100 - usedPercentage),
            windowMinutes: windowMinutes,
            resetsAt: date(from: payload["resets_at"])
        )
    }

    private static func windowLabel(forMinutes minutes: Int) -> String {
        // Codex's weekly quota window is exactly 10080 min (7d). After the
        // 5h window was removed this is usually the ONLY window, so give it
        // a self-explanatory label instead of a bare "7d".
        if minutes == 10_080 { return L10n.codexWeeklyShort }

        let days = minutes / 1_440
        let remainingMinutesAfterDays = minutes % 1_440
        let hours = remainingMinutesAfterDays / 60
        let remainingMinutes = remainingMinutesAfterDays % 60

        if days > 0, hours == 0, remainingMinutes == 0 { return "\(days)d" }
        if days > 0, hours > 0 { return "\(days)d \(hours)h" }
        if hours > 0, remainingMinutes == 0 { return "\(hours)h" }
        if hours > 0 { return "\(hours)h \(remainingMinutes)m" }
        return "\(minutes)m"
    }

    private static func jsonObject(for line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func timestamp(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func bool(from value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: return number.boolValue
        case let flag as Bool: return flag
        case let string as String: return (string as NSString).boolValue
        default: return nil
        }
    }

    private static func date(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber: return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            guard let seconds = Double(string) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        default: return nil
        }
    }

    private static func string(from value: Any?) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}
