//
//  BuddyReader.swift
//  CodeIsland
//
//  Reads Claude Code buddy data from ~/.claude.json and computes
//  deterministic bones (species, rarity, stats) using native wyhash.
//  No Bun dependency required.
//

import Combine
import Foundation
import SwiftUI

// Note: Color(hex:) initializer has been lifted to
// ClaudeIsland/UI/Helpers/Color+Hex.swift so palette code elsewhere
// in the app can use it without importing BuddyReader.

// MARK: - Buddy Types

enum BuddyRarity: String, Sendable {
    case common, uncommon, rare, epic, legendary
    var displayName: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .common: return Color(hex: "9CA3AF")
        case .uncommon: return Color(hex: "4ADE80")
        case .rare: return Color(hex: "60A5FA")
        case .epic: return Color(hex: "A78BFA")
        case .legendary: return Color(hex: "FBBF24")
        }
    }
    var stars: String {
        switch self {
        case .common: return "★"
        case .uncommon: return "★★"
        case .rare: return "★★★"
        case .epic: return "★★★★"
        case .legendary: return "★★★★★"
        }
    }
}

struct BuddyStats: Sendable {
    let debugging: Int
    let patience: Int
    let chaos: Int
    let wisdom: Int
    let snark: Int
}

enum BuddySpecies: String, CaseIterable, Sendable {
    case duck, goose, blob, cat, dragon, octopus, owl, penguin, turtle, snail
    case ghost, axolotl, capybara, cactus, robot, rabbit, mushroom, chonk
    case unknown

    var emoji: String {
        switch self {
        case .duck: return "🦆"
        case .goose: return "🪿"
        case .cat: return "🐱"
        case .rabbit: return "🐰"
        case .owl: return "🦉"
        case .penguin: return "🐧"
        case .turtle: return "🐢"
        case .snail: return "🐌"
        case .dragon: return "🐉"
        case .octopus: return "🐙"
        case .axolotl: return "🦎"
        case .ghost: return "👻"
        case .robot: return "🤖"
        case .blob: return "🫧"
        case .cactus: return "🌵"
        case .mushroom: return "🍄"
        case .chonk: return "🐈"
        case .capybara: return "🦫"
        case .unknown: return "🐾"
        }
    }
}

struct BuddyInfo: Sendable {
    let name: String
    let personality: String
    let species: BuddySpecies
    let rarity: BuddyRarity
    let stats: BuddyStats
    let eye: String
    let hat: String
    let isShiny: Bool
    let hatchedAt: Date?
}

// MARK: - Buddy Reader

class BuddyReader: ObservableObject {
    static let shared = BuddyReader()

    @Published var buddy: BuddyInfo?

    private init() {
        reload()
    }

    func reload() {
        let configPath = ConfigPaths.claudeBuddyFile
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let companion = json["companion"] as? [String: Any],
              let name = companion["name"] as? String,
              let personality = companion["personality"] as? String else {
            buddy = nil
            return
        }

        let hatchedAt: Date? = (companion["hatchedAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000.0)
        }

        // Get userId for deterministic bones computation
        let userId: String
        if let oauth = json["oauthAccount"] as? [String: Any],
           let uuid = oauth["accountUuid"] as? String {
            userId = uuid
        } else if let uid = json["userID"] as? String {
            userId = uid
        } else {
            userId = "anon"
        }

        // Try to get accurate bones via bun (cached), fallback to Swift wyhash
        let salt = Self.readSalt()
        let bones: Bones
        if let cached = Self.readCachedBones() {
            bones = cached
        } else if let bunBones = Self.computeBonesViaBun(userId: userId, salt: salt) {
            // Bun available → use Bun.hash (wyhash), matches native Claude Code install
            bones = bunBones
        } else {
            // No Bun → detect if Claude Code uses Bun (native) or Node (npm)
            let isNativeInstall = FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/claude/versions"
            )
            if isNativeInstall {
                // Native install uses Bun.hash (wyhash) — use Swift wyhash
                bones = Self.computeBonesWyhash(userId: userId, salt: salt)
            } else {
                // npm install uses Node FNV-1a
                bones = Self.computeBonesFnv1a(userId: userId, salt: salt)
            }
            Self.cacheBones(bones)
        }

        buddy = BuddyInfo(
            name: name,
            personality: personality,
            species: bones.species,
            rarity: bones.rarity,
            stats: bones.stats,
            eye: bones.eye,
            hat: bones.hat,
            isShiny: bones.isShiny,
            hatchedAt: hatchedAt
        )
    }

    // MARK: - Salt Detection

    private static let originalSalt = "friend-2026-401"

    private static func readSalt() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 1. Check cached salt file (written by any-buddy or CodeIsland setup)
        let cachePath = ConfigPaths.claudeSaltCache.path
        if let cached = try? String(contentsOfFile: cachePath, encoding: .utf8),
           cached.count == originalSalt.count,
           cached.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            return cached
        }

        // 2. Scan Claude binaries for patched salt
        let versionsDir = "\(home)/.local/share/claude/versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsDir) else {
            return originalSalt
        }

        let binaries = versions
            .filter { !$0.contains(".bak") && !$0.contains(".anybuddy") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }

        let origBytes = Data(originalSalt.utf8)

        for binary in binaries {
            let binaryPath = "\(versionsDir)/\(binary)"

            // Use mmap for efficient large file scanning
            guard let binaryData = try? Data(contentsOf: URL(fileURLWithPath: binaryPath), options: .mappedIfSafe) else { continue }

            if binaryData.range(of: origBytes) != nil {
                return originalSalt
            }

            // Patched — extract from backup
            for suffix in [".anybuddy-bak", ".bak"] {
                let bakPath = binaryPath + suffix
                guard FileManager.default.fileExists(atPath: bakPath),
                      let bakData = try? Data(contentsOf: URL(fileURLWithPath: bakPath), options: .mappedIfSafe),
                      let range = bakData.range(of: origBytes) else { continue }
                let offset = range.lowerBound
                let end = offset + origBytes.count
                guard end <= binaryData.count else { continue }
                let patchedBytes = binaryData[offset..<end]
                if let salt = String(data: Data(patchedBytes), encoding: .utf8),
                   salt.count == originalSalt.count,
                   salt.allSatisfy({ $0.isASCII && !$0.isNewline }) {
                    // Cache for next time
                    try? salt.write(toFile: cachePath, atomically: true, encoding: .utf8)
                    return salt
                }
            }
        }

        return originalSalt
    }

    // MARK: - Cached Bones

    private static let bonesCachePath = ConfigPaths.claudeBonesCache.path

    private static func readCachedBones() -> Bones? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: bonesCachePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parseBones(json)
    }

    private static func cacheBones(_ bones: Bones) {
        let stats = ["DEBUGGING": bones.stats.debugging, "PATIENCE": bones.stats.patience,
                     "CHAOS": bones.stats.chaos, "WISDOM": bones.stats.wisdom, "SNARK": bones.stats.snark]
        let dict: [String: Any] = [
            "species": bones.species.rawValue, "rarity": bones.rarity.rawValue,
            "eye": bones.eye, "hat": bones.hat, "shiny": bones.isShiny, "stats": stats
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: URL(fileURLWithPath: bonesCachePath))
        }
    }

    private static func parseBones(_ json: [String: Any]) -> Bones? {
        guard let speciesStr = json["species"] as? String,
              let rarityStr = json["rarity"] as? String,
              let species = BuddySpecies(rawValue: speciesStr),
              let rarity = BuddyRarity(rawValue: rarityStr) else { return nil }
        let statsDict = json["stats"] as? [String: Int] ?? [:]
        return Bones(
            species: species, rarity: rarity,
            stats: BuddyStats(debugging: statsDict["DEBUGGING"] ?? 0, patience: statsDict["PATIENCE"] ?? 0,
                              chaos: statsDict["CHAOS"] ?? 0, wisdom: statsDict["WISDOM"] ?? 0, snark: statsDict["SNARK"] ?? 0),
            eye: json["eye"] as? String ?? "·", hat: json["hat"] as? String ?? "none",
            isShiny: json["shiny"] as? Bool ?? false
        )
    }

    // MARK: - Bun Computation (most accurate — uses Bun.hash/wyhash like Claude Code)

    private static func computeBonesViaBun(userId: String, salt: String) -> Bones? {
        // Search for bun only — Claude Code always uses Bun.hash (wyhash)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bunPaths = [
            home + "/bin/bun", home + "/.bun/bin/bun",
            "/opt/homebrew/bin/bun", "/usr/local/bin/bun",
        ]
        guard let bunPath = bunPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }

        let script = """
        function H(s){return Number(BigInt(Bun.hash(s))&0xffffffffn)}
        const S=['duck','goose','blob','cat','dragon','octopus','owl','penguin','turtle','snail','ghost','axolotl','capybara','cactus','robot','rabbit','mushroom','chonk'];
        const R=['common','uncommon','rare','epic','legendary'];
        const W={common:60,uncommon:25,rare:10,epic:4,legendary:1};
        const E=['·','✦','×','◉','@','°'];
        const HH=['none','crown','tophat','propeller','halo','wizard','beanie','tinyduck'];
        const SN=['DEBUGGING','PATIENCE','CHAOS','WISDOM','SNARK'];
        const RF={common:5,uncommon:15,rare:25,epic:35,legendary:50};
        function m32(s){let a=s>>>0;return()=>{a|=0;a=(a+0x6d2b79f5)|0;let t=Math.imul(a^(a>>>15),1|a);t=(t+Math.imul(t^(t>>>7),61|t))^t;return((t^(t>>>14))>>>0)/4294967296}}
        function pick(r,a){return a[Math.floor(r()*a.length)]}
        const h=H('\(userId)'+'\(salt)');
        const r=m32(h);
        let roll=r()*100,rarity='common';
        for(const rr of R){roll-=W[rr];if(roll<0){rarity=rr;break}}
        const species=pick(r,S),eye=pick(r,E);
        const hat=rarity==='common'?'none':pick(r,HH);
        const shiny=r()<0.01;
        const fl=RF[rarity];
        const peak=pick(r,SN);let dump=pick(r,SN);while(dump===peak)dump=pick(r,SN);
        const stats={};
        for(const n of SN){if(n===peak)stats[n]=Math.min(100,fl+50+Math.floor(r()*30));else if(n===dump)stats[n]=Math.max(1,fl-10+Math.floor(r()*15));else stats[n]=fl+Math.floor(r()*40)}
        console.log(JSON.stringify({species,rarity,eye,hat,shiny,stats}))
        """

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: bunPath)
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bones = parseBones(json) else { return nil }
            cacheBones(bones)
            return bones
        } catch {
            return nil
        }
    }

    // MARK: - Bones Computation (Mulberry32 + WyHash — fallback)

    private struct Bones {
        let species: BuddySpecies
        let rarity: BuddyRarity
        let stats: BuddyStats
        let eye: String
        let hat: String
        let isShiny: Bool
    }

    /// Mulberry32 PRNG — same as Claude Code's implementation
    private struct Mulberry32 {
        var state: UInt32

        init(seed: UInt32) {
            self.state = seed
        }

        mutating func next() -> Double {
            state &+= 0x6D2B79F5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t = (t &+ ((t ^ (t >> 7)) &* (t | 61))) ^ t
            let result = (t ^ (t >> 14))
            return Double(result) / 4294967296.0
        }
    }

    /// FNV-1a hash — matches Claude Code's Node (non-Bun) path
    private static func fnv1aHash(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for c in s.utf8 {
            h ^= UInt32(c)
            h = h &* 16777619
        }
        return h
    }

    private static func computeBonesFnv1a(userId: String, salt: String) -> Bones {
        let key = userId + salt
        let seed = fnv1aHash(key)
        return rollBones(seed: seed)
    }

    private static func computeBonesWyhash(userId: String, salt: String) -> Bones {
        let key = userId + salt
        let hash = WyHash.hash(key)
        let seed = UInt32(hash & 0xFFFFFFFF)
        return rollBones(seed: seed)
    }

    private static func rollBones(seed: UInt32) -> Bones {
        var rng = Mulberry32(seed: seed)

        // Rarity FIRST (must match Claude Code's rollFrom order)
        let rarityWeights: [(BuddyRarity, Int)] = [(.common, 60), (.uncommon, 25), (.rare, 10), (.epic, 4), (.legendary, 1)]
        var roll = rng.next() * 100.0
        var rarity: BuddyRarity = .common
        for (r, w) in rarityWeights {
            roll -= Double(w)
            if roll < 0 { rarity = r; break }
        }

        // Species SECOND
        let speciesAll: [BuddySpecies] = [.duck, .goose, .blob, .cat, .dragon, .octopus, .owl, .penguin, .turtle, .snail, .ghost, .axolotl, .capybara, .cactus, .robot, .rabbit, .mushroom, .chonk]
        let species = speciesAll[Int(floor(rng.next() * Double(speciesAll.count)))]

        // Eye
        let eyes = ["·", "✦", "×", "◉", "@", "°"]
        let eye = eyes[Int(floor(rng.next() * Double(eyes.count)))]

        // Hat
        let hats = ["none", "crown", "tophat", "propeller", "halo", "wizard", "beanie", "tinyduck"]
        let hat = rarity == .common ? "none" : hats[Int(floor(rng.next() * Double(hats.count)))]

        // Shiny
        let isShiny = rng.next() < 0.01

        // Stats
        let statNames = ["DEBUGGING", "PATIENCE", "CHAOS", "WISDOM", "SNARK"]
        let rarityFloor: [BuddyRarity: Int] = [.common: 5, .uncommon: 15, .rare: 25, .epic: 35, .legendary: 50]
        let statFloor = rarityFloor[rarity] ?? 5

        let peak = statNames[Int(floor(rng.next() * Double(statNames.count)))]
        var dump = statNames[Int(floor(rng.next() * Double(statNames.count)))]
        while dump == peak { dump = statNames[Int(floor(rng.next() * Double(statNames.count)))] }

        var statValues = [String: Int]()
        for name in statNames {
            if name == peak {
                statValues[name] = min(100, statFloor + 50 + Int(floor(rng.next() * 30)))
            } else if name == dump {
                statValues[name] = max(1, statFloor - 10 + Int(floor(rng.next() * 15)))
            } else {
                statValues[name] = statFloor + Int(floor(rng.next() * 40))
            }
        }

        return Bones(
            species: species,
            rarity: rarity,
            stats: BuddyStats(
                debugging: statValues["DEBUGGING"] ?? 0,
                patience: statValues["PATIENCE"] ?? 0,
                chaos: statValues["CHAOS"] ?? 0,
                wisdom: statValues["WISDOM"] ?? 0,
                snark: statValues["SNARK"] ?? 0
            ),
            eye: eye,
            hat: hat,
            isShiny: isShiny
        )
    }
}
