//
//  DebugLogger.swift
//  CodeIsland
//
//  Lightweight debug logging to file for runtime diagnostics.
//  Logs are written to ~/.claude/.codeisland.log
//  Tail the log: tail -f ~/.claude/.codeisland.log
//

import Foundation

enum DebugLogger: Sendable {
    private static let logPath = NSHomeDirectory() + "/.claude/.codeisland.log"
    /// One rolled-over backup is kept alongside the active log.
    private static let rotatedPath = NSHomeDirectory() + "/.claude/.codeisland.log.1"
    /// Rotate the active log once it grows past this. Keeps disk use bounded to
    /// ~2× this (active + one backup) instead of the unbounded 173MB seen in
    /// issue #95. Rotation drops the previous backup.
    private static let maxLogBytes: UInt64 = 10 * 1024 * 1024

    private nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "com.codeisland.logger", qos: .utility)

    // Consecutive-duplicate collapsing (issue #95): the CP pipeline can emit the
    // exact same line hundreds of times in a row. We suppress identical repeats
    // and, when the content finally changes, emit a single "repeated Nx" summary
    // so no information is lost. All of this state is touched only inside
    // `queue` (serial), so the unchecked mutation is safe.
    private nonisolated(unsafe) static var lastPayload: String?
    private nonisolated(unsafe) static var repeatCount: Int = 0

    /// Log a debug message with category tag
    nonisolated static func log(_ category: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let payload = "[\(category)] \(message)"

        queue.async {
            if payload == lastPayload {
                repeatCount += 1
                return
            }
            if repeatCount > 0, let last = lastPayload {
                writeLine("[\(timestamp)] [Logger] previous line repeated \(repeatCount)× — \(last)\n")
                repeatCount = 0
            }
            lastPayload = payload
            writeLine("[\(timestamp)] \(payload)\n")
        }
    }

    /// Append a line to the log, rotating first if it has grown too large.
    /// MUST be called on `queue` — serializes rotation with writes.
    private static func writeLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    /// If the active log exceeds `maxLogBytes`, copy it to the `.1` backup
    /// (replacing any prior backup) then truncate the active file IN PLACE.
    /// Truncating in place (rather than moving) keeps the same inode, so
    /// LogStreamer's `DispatchSource` fd stays valid and its size-decrease
    /// branch resets the live tail cleanly. Serialized via `queue`.
    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? NSNumber,
              size.uint64Value >= maxLogBytes else { return }
        try? fm.removeItem(atPath: rotatedPath)
        try? fm.copyItem(atPath: logPath, toPath: rotatedPath)
        if let fh = FileHandle(forWritingAtPath: logPath) {
            try? fh.truncate(atOffset: 0)
            try? fh.close()
        }
    }

    /// Clear the log file
    static func clear() {
        queue.async {
            lastPayload = nil
            repeatCount = 0
            try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: rotatedPath)
        }
    }
}
