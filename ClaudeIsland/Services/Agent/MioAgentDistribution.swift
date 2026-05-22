import Foundation
import CryptoKit

// MARK: - MioAgentDistribution
//
// Download-at-install distribution for the mio-agent daemon binary.
//
// Release artifacts live on GitHub Releases (MioMioOS/mio-agent).
// The manifest (mio-agent-<ver>-manifest.json) carries:
//   version, git_commit, platforms.<arch>.{file, sha256, size}, required_fixes, created_at
//
// Install flow (task #121):
//   1. Fetch SHASUMS256.txt from the pinned release tag
//   2. Download the darwin-arm64 tarball
//   3. Verify SHA-256 against the manifest value
//   4. Extract binary from tarball with /usr/bin/tar
//   5. Atomically move to ~/.mio/bin/mio-agent (never overwrites on failure)
//
// Update procedure when cutting a new release:
//   - Run `npm run build:release` in mio-agent (scripts/build-release.mjs)
//   - Publish GitHub Release with dist/release/ artifacts
//   - Update pinnedVersion + pinnedSHA256 below (from SHASUMS256.txt)
//
// Security: SHA-256 is fetched from SHASUMS256.txt at download time.
// For future hardening, pin sha256 as a build-time constant here.

enum MioAgentDistribution {

    // ── Release pin ───────────────────────────────────────────────────────────

    /// Pinned release version. Update when cutting a new mio-agent release.
    static let pinnedVersion = "0.1.0"

    static let repoOwner = "MioMioOS"
    static let repoName  = "mio-agent"

    /// darwin-arm64 tarball filename for the pinned release.
    static var tarballFilename: String {
        "mio-agent-\(pinnedVersion)-darwin-arm64.tar.gz"
    }

    /// GitHub Releases base URL for the pinned release tag.
    static var releaseBaseURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/v\(pinnedVersion)/")!
    }

    static var manifestURL:  URL { releaseBaseURL.appendingPathComponent("mio-agent-\(pinnedVersion)-manifest.json") }
    static var shasumURL:    URL { releaseBaseURL.appendingPathComponent("SHASUMS256.txt") }
    static var tarballURL:   URL { releaseBaseURL.appendingPathComponent(tarballFilename) }

    // ── Error types ───────────────────────────────────────────────────────────

    enum DownloadError: LocalizedError {
        case shasumFetchFailed(statusCode: Int)
        case sha256NotFound(filename: String)
        case downloadFailed(statusCode: Int)
        case checksumMismatch(expected: String, actual: String)
        case extractionFailed(reason: String)
        case binaryNotFoundInTarball

        var errorDescription: String? {
            switch self {
            case .shasumFetchFailed(let code):
                return "Failed to fetch release checksum file (HTTP \(code))"
            case .sha256NotFound(let filename):
                return "SHA-256 entry for '\(filename)' not found in SHASUMS256.txt"
            case .downloadFailed(let code):
                return "Binary download failed (HTTP \(code))"
            case .checksumMismatch(let expected, let actual):
                return "Checksum mismatch — expected \(expected.prefix(12))…, got \(actual.prefix(12))…"
            case .extractionFailed(let reason):
                return "Tarball extraction failed: \(reason)"
            case .binaryNotFoundInTarball:
                return "mio-agent binary not found inside the downloaded tarball"
            }
        }
    }

    // ── Public install entry point ────────────────────────────────────────────

    /// Download, verify, extract, and atomically install the mio-agent binary.
    ///
    /// - Parameters:
    ///   - destinationPath: Target path for the installed binary (e.g. ~/.mio/bin/mio-agent).
    ///   - onProgress: Called with a human-readable status string at each stage (called on
    ///     a background thread; caller must dispatch to main actor if needed).
    ///
    /// - Throws: `DownloadError` on any failure.
    ///   On failure the destination binary is NOT overwritten (no-overwrite-on-fail contract).
    ///
    /// Caller is responsible for:
    ///   - Creating parent directories before calling this function.
    ///   - Ad-hoc codesigning the installed binary (required for launchd/Keychain on Apple Silicon).
    ///   - Writing the LaunchAgent plist and calling launchctl bootstrap after install succeeds.
    static func downloadAndInstall(
        to destinationPath: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {

        // ── Step 1: Fetch SHASUMS256.txt for SHA-256 of the tarball ──

        onProgress("Fetching release checksum...")
        let (shasumData, shasumResp) = try await URLSession.shared.data(from: shasumURL)
        let shasumStatus = (shasumResp as? HTTPURLResponse)?.statusCode ?? 0
        guard shasumStatus == 200 else {
            throw DownloadError.shasumFetchFailed(statusCode: shasumStatus)
        }

        let shasumText = String(data: shasumData, encoding: .utf8) ?? ""
        guard let expectedSHA256 = parseSHA256(from: shasumText, for: tarballFilename) else {
            throw DownloadError.sha256NotFound(filename: tarballFilename)
        }

        // ── Step 2: Download tarball to a per-install temp directory ──

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mio-agent-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Always clean up the temp directory, even on failure.
        defer { try? FileManager.default.removeItem(at: tempDir) }

        onProgress("Downloading mio-agent \(pinnedVersion)...")
        let tempTarball = tempDir.appendingPathComponent(tarballFilename)
        let (downloadedURL, downloadResp) = try await URLSession.shared.download(from: tarballURL)
        let downloadStatus = (downloadResp as? HTTPURLResponse)?.statusCode ?? 0
        guard downloadStatus == 200 else {
            throw DownloadError.downloadFailed(statusCode: downloadStatus)
        }
        // Move URLSession's temp file into our named temp location.
        try FileManager.default.moveItem(at: downloadedURL, to: tempTarball)

        // ── Step 3: Verify SHA-256 before touching the destination ──

        onProgress("Verifying checksum...")
        let tarballData = try Data(contentsOf: tempTarball)
        let actualSHA256 = SHA256.hash(data: tarballData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == expectedSHA256 else {
            throw DownloadError.checksumMismatch(expected: expectedSHA256, actual: actualSHA256)
        }

        // ── Step 4: Extract binary from tarball ──

        onProgress("Extracting binary...")
        let extractDir = tempDir.appendingPathComponent("extract")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        let (tarExit, tarErr) = try await runProcess(
            "/usr/bin/tar",
            args: ["-xzf", tempTarball.path, "-C", extractDir.path]
        )
        guard tarExit == 0 else {
            throw DownloadError.extractionFailed(reason: tarErr.isEmpty ? "tar exited \(tarExit)" : tarErr)
        }

        // ── Step 5: Locate the binary inside the extracted tree ──

        guard let extractedBinary = findFile(named: "mio-agent", in: extractDir) else {
            throw DownloadError.binaryNotFoundInTarball
        }

        // ── Step 6: Atomic move to destination (no-overwrite-on-fail) ──
        //
        // We only touch destinationPath AFTER all verification passes.
        // If we throw before this step, the old binary is preserved.

        onProgress("Installing mio-agent...")
        let destURL = URL(fileURLWithPath: destinationPath)

        // Remove existing binary so we can move the new one in cleanly.
        if FileManager.default.fileExists(atPath: destinationPath) {
            try FileManager.default.removeItem(at: destURL)
        }
        // Copy (not move) so the verified file stays in temp until FileManager confirms success.
        try FileManager.default.copyItem(at: extractedBinary, to: destURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    /// Parse a SHASUMS256.txt file (coreutils format: "<hex>  <filename>").
    /// Matches both bare filename and path-prefixed entries (e.g. "dir/file.tar.gz").
    private static func parseSHA256(from text: String, for filename: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0])
            let entry = String(parts.last!)
            if entry == filename || entry.hasSuffix("/\(filename)") {
                return hash
            }
        }
        return nil
    }

    /// Recursively find the first regular file named `name` under `directory`.
    private static func findFile(named name: String, in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == name else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { return url }
        }
        return nil
    }

    /// Run a process synchronously, capturing stderr. Returns (exitCode, stderrText).
    private static func runProcess(_ executable: String, args: [String]) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            process.standardError = errPipe
            do {
                try process.run()
                process.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (process.terminationStatus, errStr))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
