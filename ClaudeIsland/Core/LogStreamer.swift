//
//  LogStreamer.swift
//  ClaudeIsland
//
//  Live tail of ~/.claude/.codeisland.log for the Settings → Logs tab.
//
//  Watches the log file with DispatchSource, reads appended bytes since
//  the last read, and publishes a capped ring buffer of recent lines.
//  On app launch the backing file is loaded tail-first (last N lines only)
//  so we don't pay a huge cost for multi-MB historical logs.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class LogStreamer: ObservableObject {
    static let shared = LogStreamer()

    /// How many trailing lines to keep in memory. The UI caps its render at
    /// this many lines — historical content lives on disk only.
    private let maxLines = 1000

    @Published private(set) var lines: [String] = []

    private let logPath = ConfigPaths.claudeLogFile.path
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var readOffset: UInt64 = 0
    private var leftoverBuffer = ""
    private var subscriberCount = 0

    /// Path shown in the UI for "Open log file" / clipboard inclusion.
    var logFilePath: String { logPath }

    /// Begin tailing. Safe to call multiple times — uses reference counting so
    /// the watcher only tears down when the last subscriber disappears.
    func startIfNeeded() {
        subscriberCount += 1
        guard subscriberCount == 1 else { return }

        loadInitialTail()
        installWatcher()
    }

    /// Mirror of `startIfNeeded()` — call when a log view goes away.
    func stopIfUnused() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else { return }
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    /// Full in-memory buffer joined with newlines. For "Copy All" + issue body.
    func currentSnapshot() -> String {
        lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func loadInitialTail() {
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else {
            lines = []
            readOffset = 0
            return
        }
        let allLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        // Drop the trailing empty element from a file ending in \n.
        let trimmed: [String]
        if allLines.last == "" { trimmed = Array(allLines.dropLast()) } else { trimmed = allLines }
        lines = Array(trimmed.suffix(maxLines))
        readOffset = UInt64(data.count)
    }

    private func installWatcher() {
        // Open r/o and watch for writes & renames. Log rotation (truncate, move)
        // is handled by the .rename / size-decrease branches in the event handler.
        let fd = open(logPath, O_EVTONLY | O_RDONLY)
        guard fd >= 0 else {
            DebugLogger.log("LogStreamer", "open() failed for \(logPath) errno=\(errno)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        src.setCancelHandler {
            close(fd)
        }
        source = src
        src.resume()
    }

    private func handleEvent() {
        // Stat the file. If it got smaller (rotated/truncated) or vanished,
        // reload from scratch.
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath)
        let size = (attrs?[.size] as? UInt64) ?? 0
        if size < readOffset {
            // File was rotated/truncated. Reset.
            readOffset = 0
            leftoverBuffer = ""
            lines.removeAll()
        }

        guard let handle = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: readOffset)
        } catch {
            return
        }
        let data = handle.availableData
        if data.isEmpty { return }
        readOffset += UInt64(data.count)

        guard let chunk = String(data: data, encoding: .utf8) else { return }
        // Chunk may end mid-line — stash the tail for next time.
        let combined = leftoverBuffer + chunk
        if combined.hasSuffix("\n") {
            appendRawBlock(combined)
            leftoverBuffer = ""
        } else if let lastNewline = combined.lastIndex(of: "\n") {
            let complete = String(combined[..<lastNewline])
            leftoverBuffer = String(combined[combined.index(after: lastNewline)...])
            appendRawBlock(complete + "\n")
        } else {
            leftoverBuffer = combined
        }
    }

    private func appendRawBlock(_ block: String) {
        let newLines = block
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        // Drop the trailing empty from the final \n.
        let toAppend: [String]
        if newLines.last == "" { toAppend = Array(newLines.dropLast()) } else { toAppend = newLines }
        if toAppend.isEmpty { return }
        lines.append(contentsOf: toAppend)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}
