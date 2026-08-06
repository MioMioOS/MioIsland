//
//  DebugLogger.swift
//  CodeIsland
//
//  Lightweight debug logging to file for runtime diagnostics.
//

import Foundation

enum DebugLogger: Sendable {
    private static let logPath = ConfigPaths.claudeLogFile.path
    private nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "com.codeisland.logger", qos: .utility)

    /// Log a debug message with category tag
    nonisolated static func log(_ category: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] \(message)\n"

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    /// Clear the log file
    static func clear() {
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}
