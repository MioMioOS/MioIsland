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
//   1. Fetch manifest JSON; assert required_fixes ⊇ {machine-api-v1-prefix, socketio-control-path}
//      (anti-rollback gate from task #118/#120 — rejects stale releases even if SHA matches)
//   2. Fetch SHASUMS256.txt from the pinned release tag
//   3. Download the darwin-arm64 tarball
//   4. Verify SHA-256 against SHASUMS256.txt value
//   5. Extract binary from tarball with /usr/bin/tar
//   6. Copy to dest.staging, then FileManager.replaceItemAt (atomic; old binary survives failure)
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

    /// Name of the SEA binary INSIDE the tarball (build-release.mjs packs it as this name).
    /// Keep in sync with `seaBinary` in scripts/build-release.mjs in the mio-agent repo.
    static var binaryFilename: String {
        "mio-agent-\(pinnedVersion)-darwin-arm64"
    }

    /// GitHub Releases base URL for the pinned release tag.
    static var releaseBaseURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/v\(pinnedVersion)/")!
    }

    static var manifestURL:  URL { releaseBaseURL.appendingPathComponent("mio-agent-\(pinnedVersion)-manifest.json") }
    static var shasumURL:    URL { releaseBaseURL.appendingPathComponent("SHASUMS256.txt") }
    static var tarballURL:   URL { releaseBaseURL.appendingPathComponent(tarballFilename) }

    // ── Anti-rollback contract (task #118/#120) ───────────────────────────────

    /// Fixes that MUST be present in a release's manifest before we allow installation.
    /// A release that pre-dates these fixes is rejected even if its SHA-256 matches.
    static let requiredFixes: Set<String> = [
        "machine-api-v1-prefix",
        "socketio-control-path",
    ]

    // ── Manifest type ─────────────────────────────────────────────────────────

    /// Subset of the release manifest we care about for install-time validation.
    private struct Manifest: Decodable {
        let version: String
        let required_fixes: [String]
    }

    // ── Error types ───────────────────────────────────────────────────────────

    enum DownloadError: LocalizedError {
        case manifestFetchFailed(statusCode: Int)
        case requiredFixesMissing(fixes: [String])
        case shasumFetchFailed(statusCode: Int)
        case sha256NotFound(filename: String)
        case downloadFailed(statusCode: Int)
        case checksumMismatch(expected: String, actual: String)
        case extractionFailed(reason: String)
        case binaryNotFoundInTarball

        var errorDescription: String? {
            switch self {
            case .manifestFetchFailed(let code):
                return "Failed to fetch release manifest (HTTP \(code))"
            case .requiredFixesMissing(let fixes):
                return "Release is missing required fixes: \(fixes.joined(separator: ", ")). " +
                       "This release is too old to install safely — update pinnedVersion."
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
    ///   - Codesigning the installed binary. For the current ad-hoc-signed release,
    ///     `codesign --sign - --force <path>` is harmless. If the release ships a
    ///     Developer-ID signature in future, probe the existing signature first —
    ///     do NOT ad-hoc re-sign (it strips the notarisation seal).
    ///   - Writing the LaunchAgent plist and calling `launchctl bootstrap gui/<uid>`
    ///     (NOT `user/<uid>` — that is the #114/#79 domain bug) after install succeeds.
    static func downloadAndInstall(
        to destinationPath: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {

        // ── Step 1: Fetch and validate release manifest ──
        //
        // The manifest carries a `required_fixes` array that lists all bug-fixes
        // present in this release. We reject any release that is missing the
        // mandatory fixes from task #118/#120 — even if its SHA-256 matches —
        // to prevent a pinned-but-stale release from installing a buggy daemon.

        onProgress("Verifying release manifest...")
        let (manifestData, manifestResp) = try await URLSession.shared.data(from: manifestURL)
        let manifestStatus = (manifestResp as? HTTPURLResponse)?.statusCode ?? 0
        guard manifestStatus == 200 else {
            throw DownloadError.manifestFetchFailed(statusCode: manifestStatus)
        }

        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let presentFixes = Set(manifest.required_fixes)
        let missingFixes = Self.requiredFixes.subtracting(presentFixes)
        guard missingFixes.isEmpty else {
            throw DownloadError.requiredFixesMissing(fixes: Array(missingFixes).sorted())
        }

        // ── Step 2: Fetch SHASUMS256.txt for SHA-256 of the tarball ──

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

        // ── Step 3: Download tarball to a per-install temp directory ──

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

        // ── Step 4: Verify SHA-256 before touching the destination ──

        onProgress("Verifying checksum...")
        let tarballData = try Data(contentsOf: tempTarball)
        let actualSHA256 = SHA256.hash(data: tarballData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == expectedSHA256 else {
            throw DownloadError.checksumMismatch(expected: expectedSHA256, actual: actualSHA256)
        }

        // ── Step 5: Extract binary from tarball ──

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

        // ── Step 6: Locate the binary inside the extracted tree ──
        //
        // build-release.mjs packs the SEA binary as "mio-agent-<ver>-darwin-arm64"
        // (NOT plain "mio-agent"). Use binaryFilename to match the actual name.

        guard let extractedBinary = findFile(named: binaryFilename, in: extractDir) else {
            throw DownloadError.binaryNotFoundInTarball
        }

        // ── Step 7: Stage-then-atomic-replace (true no-overwrite-on-fail) ──
        //
        // We copy the verified binary to a sibling staging path first.
        // The OLD binary at destinationPath is NEVER removed until the staging
        // copy is complete and the atomic swap succeeds. On any failure before
        // the swap, the old binary is intact.
        //
        // FileManager.replaceItemAt(_:withItemAt:) maps to renameat(2) on the
        // same volume — atomic on HFS+/APFS. It also handles the case where
        // the destination does not yet exist (first install).
        //
        // Note on codesigning: ad-hoc re-signing (--sign -) is harmless for the
        // current ad-hoc-signed release. If the release ships with a Developer-ID
        // signature in future, callers MUST NOT ad-hoc re-sign — doing so will
        // strip the notarisation seal. Caller should probe the existing signature
        // before deciding whether to sign.

        onProgress("Installing mio-agent...")
        let destURL = URL(fileURLWithPath: destinationPath)
        let stagingURL = URL(fileURLWithPath: destinationPath + ".staging")

        // Remove any leftover staging file from a previous failed attempt.
        try? FileManager.default.removeItem(at: stagingURL)

        // Copy verified binary into staging (old dest is untouched on failure here).
        try FileManager.default.copyItem(at: extractedBinary, to: stagingURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingURL.path)

        // Atomic swap: old binary survives until this line returns successfully.
        if FileManager.default.fileExists(atPath: destinationPath) {
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: stagingURL)
        } else {
            // First install — no existing binary to preserve; just move staging into place.
            try FileManager.default.moveItem(at: stagingURL, to: destURL)
        }
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
