//
//  CmuxBinary.swift
//  ClaudeIsland
//
//  Single source of truth for locating the cmux CLI binary.
//
//  Previously `LaunchService` probed five candidate paths while
//  `TerminalWriter` hardcoded only `/Applications/cmux.app/Contents/Resources/bin/cmux`.
//  The result: a user whose cmux lives anywhere else (Homebrew, ~/Applications,
//  a renamed copy) could *launch* sessions fine (LaunchService found it) but
//  every phone→terminal *relay* silently failed — and the diagnostics tab even
//  reported "cmux not installed" while cmux was clearly running. See issues
//  #49 ("brew 安装的 Cmux…发消息没有任何反应") and #62.
//

import AppKit
import Foundation

/// Resolves the path to the cmux CLI. Used by both the launcher and the relay
/// so they agree on where cmux is.
enum CmuxBinary {
    static let bundleId = "com.cmuxterm.app"

    private static let lock = NSLock()
    private static var cached: String?

    /// Every location we know cmux's CLI can live at, in priority order.
    /// Exposed so the diagnostics tab can show the user exactly where we looked.
    ///
    /// The first entry is derived from the *running* cmux app's own bundle —
    /// the most robust source, since it finds cmux wherever it was installed
    /// (including a Homebrew cask in /Applications, ~/Applications, or a
    /// relocated/renamed copy). The static list covers cmux that's installed
    /// but not currently running.
    static var candidatePaths: [String] {
        var paths: [String] = []

        if let bundleURL = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId)
            .first?.bundleURL {
            paths.append(bundleURL.appendingPathComponent("Contents/Resources/bin/cmux").path)
        }

        let home = NSHomeDirectory()
        paths += [
            // Homebrew / user installs
            "/opt/homebrew/bin/cmux",
            "/usr/local/bin/cmux",
            "\(home)/.local/bin/cmux",
            // cmux.app bundle install
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "\(home)/Applications/cmux.app/Contents/Resources/bin/cmux",
        ]
        return paths
    }

    /// First existing executable among the candidate paths, or nil if cmux
    /// can't be found anywhere.
    ///
    /// A successful resolve is cached (the path rarely changes within a
    /// session). The cache is re-validated with `isExecutableFile` on each
    /// call, and a `nil` result is never cached — so opening/installing cmux
    /// mid-session is picked up automatically without a restart. The
    /// diagnostics "refresh" button can pass `forceRefresh: true` to re-scan.
    ///
    /// Thread-safe: `NSRunningApplication` and `FileManager` are usable from
    /// any thread and the cache is `NSLock`-guarded, so this is callable from
    /// the `nonisolated` contexts in `TerminalWriter`.
    static func resolvedPath(forceRefresh: Bool = false) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if !forceRefresh,
           let cached,
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        let found = candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        cached = found  // storing nil simply means "re-scan next time"
        return found
    }
}
