#!/usr/bin/env swift
//
//  test-nonascii-session-scan.swift
//  Standalone runtime check for issue #99: the UUID-name scan fallback must
//  locate a session JSONL even when the cwd (and thus the encoded project dir)
//  contains non-ASCII characters, where the encoded-path lookup misses.
//
//  Mirrors ConversationParser.scanProjectsForFile + sessionFilePath's
//  encoded-path logic against a real temp filesystem. Run: swift <thisfile>
//

import Foundation

// --- copies of the production logic under test -------------------------------

func encodedPath(projectsRoot: String, cwd: String, sessionId: String) -> String {
    let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    return projectsRoot + "/" + projectDir + "/" + sessionId + ".jsonl"
}

func scanProjectsForFile(projectsRoot: String, named fileName: String) -> String? {
    let projectsURL = URL(fileURLWithPath: projectsRoot)
    guard let subdirs = try? FileManager.default.contentsOfDirectory(
        at: projectsURL, includingPropertiesForKeys: nil
    ) else { return nil }
    for subdir in subdirs {
        let candidate = subdir.appendingPathComponent(fileName).path
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

// --- test harness ------------------------------------------------------------

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print(cond ? "  ✓ \(label)" : "  ✗ FAIL: \(label)")
    if !cond { failures += 1 }
}

let fm = FileManager.default
let root = NSTemporaryDirectory() + "test-nonascii-\(getpid())"
let projects = root + "/projects"

// Claude Code's ACTUAL on-disk dir for a Chinese cwd: every non-ASCII char is
// also collapsed to '-'. We simulate that real directory name here.
let sessionId = "6da6225e-1234-4abc-8def-0123456789ab"
let claudeCodeDir = "-Users-yaki-le-----------"     // what Claude Code actually writes
let realFile = projects + "/" + claudeCodeDir + "/" + sessionId + ".jsonl"

do {
    try fm.createDirectory(atPath: projects + "/" + claudeCodeDir, withIntermediateDirectories: true)
    // add a couple of decoy project dirs to prove the scan picks the right one
    try fm.createDirectory(atPath: projects + "/-Users-yaki-le-other", withIntermediateDirectories: true)
    fm.createFile(atPath: projects + "/-Users-yaki-le-other/" + "aaaaaaaa-0000-4000-8000-000000000000.jsonl", contents: Data("decoy".utf8))
    fm.createFile(atPath: realFile, contents: Data("real".utf8))
} catch {
    print("setup failed: \(error)"); exit(2)
}
defer { try? fm.removeItem(atPath: root) }

let cwd = "/Users/yaki.le/工作/桌面端需求文档"

// 1. The encoded-path lookup MUST miss (this is the bug being worked around).
let encoded = encodedPath(projectsRoot: projects, cwd: cwd, sessionId: sessionId)
check(!fm.fileExists(atPath: encoded), "encoded path misses on non-ASCII cwd (\(URL(fileURLWithPath: encoded).lastPathComponent))")

// 2. The UUID scan fallback MUST find the real file. Compare by resolved path
//    (NSTemporaryDirectory can be /var while URL enumeration yields /private/var).
let scanned = scanProjectsForFile(projectsRoot: projects, named: sessionId + ".jsonl")
let sameFile: Bool = {
    guard let s = scanned else { return false }
    return URL(fileURLWithPath: s).resolvingSymlinksInPath().path
        == URL(fileURLWithPath: realFile).resolvingSymlinksInPath().path
}()
check(sameFile, "UUID scan locates the real JSONL across project dirs")

// 3. The scan must not be fooled by the decoy (different UUID).
check(scanned != nil && (try? String(contentsOfFile: scanned!)) == "real", "scan returns the correct file contents, not the decoy")

// 4. A UUID with no file anywhere returns nil (no false positive).
check(scanProjectsForFile(projectsRoot: projects, named: "ffffffff-ffff-4fff-8fff-ffffffffffff.jsonl") == nil, "missing UUID yields nil")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
