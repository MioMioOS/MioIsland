//
//  TokenUsage.swift
//  ClaudeIsland
//
//  Local-transcript token meter. Aggregates today's token consumption across
//  ALL models by reading the JSONL transcripts the official CLIs write:
//    - Claude Code:  ~/.claude/projects/<slug>/<session-uuid>.jsonl
//    - Codex CLI:    ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
//
//  Independent of subscription plan / rate-limit API: works for Free/Pro/Max,
//  for Spark, and for proxied/relayed setups (custom model_provider /
//  ANTHROPIC_BASE_URL) — the CLI writes the transcript locally regardless of
//  where requests are routed. It does NOT see tools that write neither file
//  (custom API scripts, Cursor, web clients, or SSH-remote sessions).
//
//  Models are auto-discovered from the data (message.model / limit_name).
//

import Combine
import Foundation

// MARK: - Models

/// Per-model token totals for the current day, normalized across providers.
/// "Billable" = input + output (charged at full rate). Cache-read tokens are
/// tracked separately because they are nearly free and would otherwise inflate
/// the headline by 50-100x.
struct TokenModelUsage: Equatable, Codable, Sendable, Identifiable {
    var model: String
    var provider: String       // "Claude" | "Codex"
    var billableInput: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    var id: String { provider + "/" + model }
    var billable: Int { billableInput + output }
    var cache: Int { cacheRead + cacheWrite }
    var total: Int { billable + cache }
}

struct TokenUsageSnapshot: Equatable, Codable, Sendable {
    var models: [TokenModelUsage]
    var capturedAt: Date?
    var dayStart: Date?

    var totalBillable: Int { models.reduce(0) { $0 + $1.billable } }
    var totalCache: Int { models.reduce(0) { $0 + $1.cache } }
    var isEmpty: Bool { models.isEmpty }
}

/// File identity used for cheap change-detection between poll cycles.
struct FileMeta: Equatable, Sendable {
    var size: Int
    var mtime: Date
}

/// Loader output: the snapshot plus the file-metadata fingerprint that produced
/// it, so the next cycle can skip parsing entirely when nothing changed.
struct TokenLoadResult: Sendable {
    var snapshot: TokenUsageSnapshot
    var meta: [String: FileMeta]
}

// MARK: - Monitor

@MainActor
final class TokenUsageMonitor: ObservableObject {
    static let shared = TokenUsageMonitor()

    @Published private(set) var snapshot: TokenUsageSnapshot?
    @Published private(set) var isLoading = false

    private var refreshTimer: Timer?
    /// File fingerprint from the last successful parse — lets us skip a cycle
    /// when no transcript changed (idle = stat-only, no content read).
    private var lastMeta: [String: FileMeta] = [:]

    private init() {}

    func start() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        snapshot = nil
        lastMeta = [:]
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let prior = lastMeta
        // Scan + parse off the main thread. The loader is a pure function
        // (prior fingerprint in → result out); no shared mutable state.
        let result = await Task.detached(priority: .utility) {
            TokenUsageLoader.load(prior: prior)
        }.value
        if let result {
            snapshot = result.snapshot
            lastMeta = result.meta
        }
        // result == nil → nothing changed since last cycle; keep current snapshot.
    }
}

// MARK: - Loader

enum TokenUsageLoader {
    static var claudeProjectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }
    static var codexSessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Returns nil when no qualifying file changed vs `prior` (caller keeps its
    /// existing snapshot). Otherwise parses today's transcripts and returns the
    /// fresh snapshot + file fingerprint.
    static func load(
        prior: [String: FileMeta] = [:],
        now: Date = Date(),
        claudeRoot: URL? = nil,
        codexRoot: URL? = nil,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> TokenLoadResult? {
        let dayStart = calendar.startOfDay(for: now)
        let claudeFiles = jsonlFiles(in: claudeRoot ?? claudeProjectsURL,
                                     modifiedOnOrAfter: dayStart, fileManager: fileManager)
        let codexFiles = jsonlFiles(in: codexRoot ?? codexSessionsURL,
                                    modifiedOnOrAfter: dayStart, prefix: "rollout-",
                                    fileManager: fileManager)
        var meta: [String: FileMeta] = [:]
        for (url, m) in claudeFiles { meta[url.path] = m }
        for (url, m) in codexFiles { meta[url.path] = m }

        // Change-detection: identical fingerprint → skip the content read.
        // (prior empty = first run → always parse.)
        if !prior.isEmpty && meta == prior {
            return nil
        }

        var acc: [String: TokenModelUsage] = [:]
        // Dedup Claude by logical message id ACROSS all files: a tool-use turn
        // is written once per content block, every line carrying the identical
        // message.usage. Summing per line over-counts 2-4x. Forked/resumed
        // sessions can repeat an id across files too, so the set spans the load.
        var seenClaudeIds = Set<String>()
        for (url, _) in claudeFiles {
            parseClaude(url, into: &acc, seen: &seenClaudeIds, dayStart: dayStart)
        }
        for (url, _) in codexFiles {
            parseCodex(url, into: &acc, dayStart: dayStart)
        }
        let models = acc.values
            .filter { $0.total > 0 }
            .sorted { $0.billable > $1.billable }
        let snapshot = TokenUsageSnapshot(models: models, capturedAt: now, dayStart: dayStart)
        return TokenLoadResult(snapshot: snapshot, meta: meta)
    }

    // MARK: Claude

    private static func parseClaude(
        _ url: URL, into acc: inout [String: TokenModelUsage],
        seen: inout Set<String>, dayStart: Date
    ) {
        forEachLine(in: url) { line in
            guard let obj = jsonObject(line),
                  obj["type"] as? String == "assistant",
                  let ts = isoDate(obj["timestamp"]), ts >= dayStart,
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let model = (message["model"] as? String) ?? "unknown"
            if model == "<synthetic>" { return }
            // Dedup: one logical assistant message = one count, no matter how
            // many content-block lines repeat it.
            let mid = (message["id"] as? String) ?? (obj["requestId"] as? String)
            if let mid {
                if seen.contains(mid) { return }
                seen.insert(mid)
            }
            let key = "Claude/" + model
            var entry = acc[key]
                ?? TokenModelUsage(model: model, provider: "Claude",
                                   billableInput: 0, output: 0, cacheRead: 0, cacheWrite: 0)
            entry.billableInput += intVal(usage["input_tokens"])
            entry.output += intVal(usage["output_tokens"])
            entry.cacheRead += intVal(usage["cache_read_input_tokens"])
            entry.cacheWrite += intVal(usage["cache_creation_input_tokens"])
            acc[key] = entry
        }
    }

    // MARK: Codex
    //
    // total_token_usage is CUMULATIVE per session. We walk events in order and
    // sum per-event deltas (curr − prev, clamped ≥0) whose timestamp is today.
    // Sessions spanning midnight get the correct today-only increment because
    // yesterday's events establish the prev baseline.

    private static func parseCodex(
        _ url: URL, into acc: inout [String: TokenModelUsage], dayStart: Date
    ) {
        var label = "Codex"
        var prevInput: Int?, prevCached = 0, prevOutput = 0, prevReasoning = 0
        var dInput = 0, dCached = 0, dOutput = 0, dReasoning = 0
        forEachLine(in: url) { line in
            guard let obj = jsonObject(line),
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else { return }
            if let limits = payload["rate_limits"] as? [String: Any],
               let ln = limits["limit_name"] as? String, !ln.isEmpty {
                label = ln
            }
            guard let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any] else { return }
            let cInput = intVal(totals["input_tokens"])
            let cCached = intVal(totals["cached_input_tokens"])
            let cOutput = intVal(totals["output_tokens"])
            let cReasoning = intVal(totals["reasoning_output_tokens"])
            let di = max(0, cInput - (prevInput ?? 0))
            let dc = max(0, cCached - prevCached)
            let dou = max(0, cOutput - prevOutput)
            let dr = max(0, cReasoning - prevReasoning)
            prevInput = cInput; prevCached = cCached; prevOutput = cOutput; prevReasoning = cReasoning
            guard let ts = isoDate(obj["timestamp"]), ts >= dayStart else { return }
            dInput += di; dCached += dc; dOutput += dou; dReasoning += dr
        }
        let billableInput = max(0, dInput - dCached)   // input_tokens includes cached
        let output = dOutput + dReasoning
        if billableInput + output + dCached == 0 { return }
        let key = "Codex/" + label
        var entry = acc[key]
            ?? TokenModelUsage(model: label, provider: "Codex",
                               billableInput: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        entry.billableInput += billableInput
        entry.output += output
        entry.cacheRead += dCached
        acc[key] = entry
    }

    // MARK: Line iteration (memory-mapped)

    /// Iterate JSONL lines without loading the whole file into the heap. Uses
    /// .mappedIfSafe so a 200MB+ active session is paged by the OS rather than
    /// slurped into a Swift String. `body` is non-escaping (called inline), so
    /// callers may capture inout state.
    private static func forEachLine(in url: URL, _ body: (String) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let nl: UInt8 = 0x0A
        var idx = data.startIndex
        let end = data.endIndex
        while idx < end {
            let lineEnd = data[idx..<end].firstIndex(of: nl) ?? end
            if lineEnd > idx, let line = String(data: data[idx..<lineEnd], encoding: .utf8) {
                body(line)
            }
            idx = (lineEnd < end) ? data.index(after: lineEnd) : end
        }
    }

    // MARK: File discovery

    /// (url, FileMeta) for *.jsonl under root with mtime ≥ cutoff, optionally
    /// filtered by filename prefix. The mtime filter runs before any read.
    private static func jsonlFiles(
        in root: URL, modifiedOnOrAfter cutoff: Date,
        prefix: String? = nil, fileManager: FileManager
    ) -> [(URL, FileMeta)] {
        guard fileManager.fileExists(atPath: root.path),
              let en = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        var out: [(URL, FileMeta)] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            if let prefix, !url.lastPathComponent.hasPrefix(prefix) { continue }
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]),
                  rv.isRegularFile == true,
                  let mtime = rv.contentModificationDate, mtime >= cutoff else { continue }
            out.append((url, FileMeta(size: rv.fileSize ?? 0, mtime: mtime)))
        }
        return out
    }

    // MARK: JSON / parsing helpers

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func intVal(_ v: Any?) -> Int {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
