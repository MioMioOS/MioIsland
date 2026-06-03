//
//  MioAgentLauncher.swift
//  ClaudeIsland
//
//  Task #117 — npx-cached daemon distribution.
//
//  The daemon (`@miomioos/mio-agent`) ships TWO equivalent launch shapes that run
//  the SAME CLI dispatch (login / run / etc — see mio-agent src/cli/index.ts):
//
//    A. npx-cached (PREFERRED):  npx -y @miomioos/mio-agent@<ver> <subcmd>
//       npm caches the package under ~/.npm/_npx so subsequent launches are offline-fast.
//       No SHA-pinned binary download, no ad-hoc codesign step — npm owns integrity.
//
//    B. GitHub-Release SEA binary (FALLBACK):  ~/.mio/bin/mio-agent <subcmd>
//       Used only when npx is unavailable. Installed/verified by MioAgentDistribution.
//
//  This type resolves which strategy is usable on THIS machine and returns a concrete
//  (executableURL, prefixArgs) the caller prepends to a subcommand. It NEVER fabricates
//  a path — every returned launcher is backed by a file that exists on disk.
//
//  PATH note: a GUI app launched from Finder inherits a minimal PATH
//  (/usr/bin:/bin:/usr/sbin:/sbin), so `npx`/`node` from nvm/Homebrew are NOT on it.
//  We therefore probe a fixed set of well-known install locations rather than relying
//  on PATH resolution.
//

import Foundation

enum MioAgentLauncher {

    /// The npm package + pinned version launched via npx. Keep the version in lockstep
    /// with MioAgentDistribution.pinnedVersion so both launch paths run the same release.
    static let npmPackage = "@miomioos/mio-agent"
    static var npmSpec: String { "\(npmPackage)@\(MioAgentDistribution.pinnedVersion)" }

    /// Installed SEA-binary location (the MioAgentDistribution destination).
    static var installedBinaryPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mio/bin/mio-agent").path
    }

    // MARK: - Strategy

    /// A concrete, ready-to-run launch recipe. `executablePath` and every entry in
    /// `prefixArgs` is real; append the daemon subcommand (e.g. ["login", "--server", …]).
    struct Launch: Equatable {
        enum Kind: Equatable { case npx, binary }
        let kind: Kind
        /// Absolute path to the executable to spawn (npx wrapper, or the SEA binary).
        let executablePath: String
        /// Arguments that select the daemon BEFORE the subcommand.
        /// - npx:    ["-y", "@miomioos/mio-agent@<ver>"]
        /// - binary: []
        let prefixArgs: [String]
        /// Directory containing node/npx — added to the child PATH so npx can find node
        /// even under the minimal Finder-launched PATH. Empty for the binary path.
        let toolchainDir: String?

        /// Full argv (executable + prefix + subcommand) for a given daemon subcommand.
        func argv(_ subcommand: [String]) -> [String] {
            [executablePath] + prefixArgs + subcommand
        }
    }

    /// Why no launcher is available — surfaced to the user instead of failing silently.
    enum Unavailable: Error, Equatable {
        /// Neither npx nor an installed binary was found.
        case nothingAvailable
    }

    // MARK: - Resolution

    /// Resolve the best available launch strategy: npx-cached first, installed binary as
    /// fallback. Returns `.failure(.nothingAvailable)` when neither exists so the caller
    /// can degrade gracefully with a clear message (no silent no-op).
    static func resolve() -> Result<Launch, Unavailable> {
        if let npx = findNpx() {
            return .success(Launch(
                kind: .npx,
                executablePath: npx.path,
                prefixArgs: ["-y", npmSpec],
                toolchainDir: npx.dir
            ))
        }
        if FileManager.default.isExecutableFile(atPath: installedBinaryPath) {
            return .success(Launch(
                kind: .binary,
                executablePath: installedBinaryPath,
                prefixArgs: [],
                toolchainDir: nil
            ))
        }
        return .failure(.nothingAvailable)
    }

    /// True when npx is the resolved strategy. Used to decide whether the install/download
    /// step is even needed (npx makes the GitHub-binary download optional).
    static var npxAvailable: Bool { findNpx() != nil }

    // MARK: - npx discovery

    /// Locate a real `npx` executable from well-known install roots (Finder PATH is minimal).
    /// Returns the npx path AND its containing bin dir (so node beside it is on the child PATH).
    private static func findNpx() -> (path: String, dir: String)? {
        let fm = FileManager.default
        var candidates: [String] = [
            "/opt/homebrew/bin/npx",   // Apple-silicon Homebrew
            "/usr/local/bin/npx",      // Intel Homebrew / generic
        ]

        // nvm: ~/.nvm/versions/node/<ver>/bin/npx — pick the highest semver present.
        let nvmRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node")
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot.path) {
            let sorted = versions.sorted(by: semverDescending)
            for v in sorted {
                candidates.append(nvmRoot.appendingPathComponent("\(v)/bin/npx").path)
            }
        }

        // fnm / Volta common locations.
        let home = fm.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/.volta/bin/npx")

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return (path, (path as NSString).deletingLastPathComponent)
        }
        return nil
    }

    /// Descending semver comparison for nvm version directory names like "v22.22.0".
    private static func semverDescending(_ a: String, _ b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                .split(separator: ".")
                .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Child environment

    /// Build a child-process environment that puts the node toolchain dir on PATH so
    /// `npx` can spawn `node`. For the binary path this is a no-op passthrough.
    static func childEnvironment(for launch: Launch) -> [String: String] {
        var env = Foundation.ProcessInfo.processInfo.environment
        if let dir = launch.toolchainDir {
            let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !existing.split(separator: ":").contains(Substring(dir)) {
                env["PATH"] = "\(dir):\(existing)"
            }
        }
        return env
    }
}
