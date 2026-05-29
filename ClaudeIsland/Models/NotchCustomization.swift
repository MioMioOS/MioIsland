//
//  NotchCustomization.swift
//  ClaudeIsland
//
//  Single value type holding every user-adjustable notch setting.
//  Persisted atomically by NotchCustomizationStore under the
//  UserDefaults key `notchCustomization.v1`. See
//  docs/superpowers/specs/2026-04-08-notch-customization-design.md
//  for the full architectural rationale.
//

import CoreGraphics
import Foundation

/// Per-screen geometry settings. Keyed by screen's CGDirectDisplayID
/// in NotchCustomization.screenGeometries.
struct ScreenGeometry: Codable, Equatable {
    var maxWidth: CGFloat = 440
    var horizontalOffset: CGFloat = 0
    var notchHeight: CGFloat = 38

    static let `default` = ScreenGeometry()
}

struct NotchCustomization: Codable, Equatable {
    // Appearance
    var theme: NotchThemeID
    var fontScale: FontScale
    var buddyStyle: BuddyStyle

    // Visibility toggles
    var showBuddy: Bool
    var showUsageBar: Bool

    // Per-provider sub-toggles. Honored only when showUsageBar is true.
    // Default both to true for backward compatibility with the pre-2026-05-28
    // single-toggle behavior.
    var showClaudeUsageBar: Bool = true
    var showCodexUsageBar: Bool = true

    // Usage bar display mode (auto by default — switches between compact
    // and alert based on usage; user can pin a specific mode)
    var usageBarDisplayMode: UsageBarDisplayMode = .auto

    // Per-screen geometry
    var screenGeometries: [String: ScreenGeometry] = [:]
    var defaultGeometry: ScreenGeometry = .init()

    // Hardware notch override
    var hardwareNotchMode: HardwareNotchMode

    // Hover expand speed
    var hoverSpeed: HoverSpeed = .normal

    init(
        theme: NotchThemeID = .classic,
        fontScale: FontScale = .default,
        buddyStyle: BuddyStyle = .pixelCat,
        showBuddy: Bool = true,
        showUsageBar: Bool = true,
        showClaudeUsageBar: Bool = true,
        showCodexUsageBar: Bool = true,
        usageBarDisplayMode: UsageBarDisplayMode = .auto,
        hardwareNotchMode: HardwareNotchMode = .auto,
        hoverSpeed: HoverSpeed = .normal
    ) {
        self.theme = theme
        self.fontScale = fontScale
        self.buddyStyle = buddyStyle
        self.showBuddy = showBuddy
        self.showUsageBar = showUsageBar
        self.showClaudeUsageBar = showClaudeUsageBar
        self.showCodexUsageBar = showCodexUsageBar
        self.usageBarDisplayMode = usageBarDisplayMode
        self.hardwareNotchMode = hardwareNotchMode
        self.hoverSpeed = hoverSpeed
    }

    static let `default` = NotchCustomization()

    // MARK: - Per-screen geometry helpers

    func geometry(for screenID: String) -> ScreenGeometry {
        screenGeometries[screenID] ?? defaultGeometry
    }

    mutating func updateGeometry(for screenID: String, _ body: (inout ScreenGeometry) -> Void) {
        var geo = geometry(for: screenID)
        body(&geo)
        screenGeometries[screenID] = geo
    }

    // MARK: - Forward-compat Codable
    //
    // Decoding with defaults for missing keys so that future schema
    // additions remain backward-compatible without bumping the v1
    // key. (The plan's "strict decoding" variant was a documentation
    // preference; forward-compat decoding is the pragmatic choice
    // for a Mac app shipping value types to user defaults.)

    private enum CodingKeys: String, CodingKey {
        case theme, fontScale, buddyStyle, showBuddy, showUsageBar,
             showClaudeUsageBar, showCodexUsageBar,
             usageBarDisplayMode,
             hardwareNotchMode, hoverSpeed, screenGeometries, defaultGeometry,
             maxWidth, horizontalOffset // legacy keys for migration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` because `decodeIfPresent` THROWS when the key exists but the
        // raw value isn't a case of NotchThemeID — which happens every time
        // we rename or drop themes (v1 → v2 shipped with 11 renames).
        self.theme = (try? c.decode(NotchThemeID.self, forKey: .theme)) ?? .classic
        self.fontScale = try c.decodeIfPresent(FontScale.self, forKey: .fontScale) ?? .default
        // Buddy style is new (v1.1). If absent from the persisted blob, fall
        // back to the legacy `usePixelCat` AppStorage bool so existing users
        // see what they saw before the picker shipped.
        if let decoded = try? c.decode(BuddyStyle.self, forKey: .buddyStyle) {
            self.buddyStyle = decoded
        } else if UserDefaults.standard.object(forKey: "usePixelCat") != nil {
            self.buddyStyle = UserDefaults.standard.bool(forKey: "usePixelCat") ? .pixelCat : .emoji
        } else {
            self.buddyStyle = .pixelCat
        }
        self.showBuddy = try c.decodeIfPresent(Bool.self, forKey: .showBuddy) ?? true
        self.showUsageBar = try c.decodeIfPresent(Bool.self, forKey: .showUsageBar) ?? true
        self.showClaudeUsageBar = try c.decodeIfPresent(Bool.self, forKey: .showClaudeUsageBar) ?? true
        self.showCodexUsageBar = try c.decodeIfPresent(Bool.self, forKey: .showCodexUsageBar) ?? true
        self.usageBarDisplayMode = (try? c.decode(UsageBarDisplayMode.self, forKey: .usageBarDisplayMode)) ?? .auto
        self.hardwareNotchMode = try c.decodeIfPresent(HardwareNotchMode.self, forKey: .hardwareNotchMode) ?? .auto
        self.hoverSpeed = try c.decodeIfPresent(HoverSpeed.self, forKey: .hoverSpeed) ?? .normal
        self.screenGeometries = try c.decodeIfPresent([String: ScreenGeometry].self, forKey: .screenGeometries) ?? [:]

        if let existing = try c.decodeIfPresent(ScreenGeometry.self, forKey: .defaultGeometry) {
            // New-format blob: use as-is, ignore any stale legacy keys
            self.defaultGeometry = existing
        } else {
            // No defaultGeometry key — either legacy blob or fresh install.
            // Migrate old top-level fields into a fresh default.
            var geo = ScreenGeometry()
            if let legacyWidth = try c.decodeIfPresent(CGFloat.self, forKey: .maxWidth) {
                geo.maxWidth = legacyWidth
            }
            if let legacyOffset = try c.decodeIfPresent(CGFloat.self, forKey: .horizontalOffset) {
                geo.horizontalOffset = legacyOffset
            }
            self.defaultGeometry = geo
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(theme, forKey: .theme)
        try c.encode(fontScale, forKey: .fontScale)
        try c.encode(buddyStyle, forKey: .buddyStyle)
        try c.encode(showBuddy, forKey: .showBuddy)
        try c.encode(showUsageBar, forKey: .showUsageBar)
        try c.encode(showClaudeUsageBar, forKey: .showClaudeUsageBar)
        try c.encode(showCodexUsageBar, forKey: .showCodexUsageBar)
        try c.encode(usageBarDisplayMode, forKey: .usageBarDisplayMode)
        try c.encode(hardwareNotchMode, forKey: .hardwareNotchMode)
        try c.encode(hoverSpeed, forKey: .hoverSpeed)
        try c.encode(screenGeometries, forKey: .screenGeometries)
        try c.encode(defaultGeometry, forKey: .defaultGeometry)
    }
}

/// Which sprite sits next to the status dot in the notch pill.
/// - `pixelCat`: the 13×11 hand-painted tabby from `PixelCharacterView`.
///   Reacts to 6 animation states (idle/working/needsYou/…).
/// - `emoji`: Claude Code companion emoji from `~/.claude.json`
///   (18 species — duck/cat/owl/…). Falls back to `pixelCat` when no
///   companion data exists.
///
/// NOTE: `neon` was considered (cyberpunk recolor of the pixel cat with
/// glow + hue wave) but `NeonPixelCatView` is designed for the full-size
/// loading screen and collapses into a green blob at the notch's 16×16
/// target. Pulled it from the picker rather than ship broken visuals.
enum BuddyStyle: String, Codable, CaseIterable, Identifiable {
    case pixelCat
    case emoji

    var id: String { rawValue }
}

/// Identifier for one of the built-in themes. Raw string values
/// so persisted JSON is stable across code renames.
///
/// v2 line-up (2026-04-20): reset to `classic` + six themes designed
/// via Claude Design (island/project/themes.jsx). Older raw values
/// persisted from the v1 palette ("paper", "cyber", "mint", etc.) fall
/// back to `.classic` on decode — see NotchCustomization.init(from:).
struct NotchThemeID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }

    static let classic = NotchThemeID(rawValue: "classic")
    static let forest = NotchThemeID(rawValue: "forest")
    static let neonTokyo = NotchThemeID(rawValue: "neonTokyo")
    static let sunset = NotchThemeID(rawValue: "sunset")
    static let retroArcade = NotchThemeID(rawValue: "retroArcade")
    static let highContrast = NotchThemeID(rawValue: "highContrast")
    static let sakura = NotchThemeID(rawValue: "sakura")
}

/// Four-step relative font scale. String raw values for stable
/// persistence; `CGFloat` multiplier exposed via computed property
/// so we avoid the historical fragility of `Codable` on `CGFloat`
/// raw values.
enum FontScale: String, Codable, CaseIterable {
    case small    = "small"
    case `default` = "default"
    case large    = "large"
    case xLarge   = "xLarge"

    var multiplier: CGFloat {
        switch self {
        case .small:    return 0.85
        case .default:  return 1.0
        case .large:    return 1.15
        case .xLarge:   return 1.3
        }
    }
}

/// How CodeIsland treats the MacBook's physical notch when
/// computing the panel geometry.
///
/// `auto` — detect via `NSScreen.main?.safeAreaInsets.top > 0`.
/// `forceVirtual` — ignore any hardware notch and draw a
///   virtual, user-positionable overlay (useful on external
///   displays or when the user prefers a freely-resized notch
///   even on a notched Mac).
enum HardwareNotchMode: String, Codable {
    case auto
    case forceVirtual
}

/// Display mode for the usage bar.
///
/// - `auto`: switches between `compact` and `alert` based on usage thresholds.
///   < 60% → compact (minimal). 60-80% → alert (enlarged, attention-grabbing).
///   > 80% → alert + pulsing red. This is the default and resolves the
///   "I can't tell when usage is getting close to limit" UX problem
///   automatically.
/// - `alert`: always show the enlarged warning-oriented layout (bigger
///   percentage numbers, thicker progress bar with glow).
/// - `compact`: the legacy layout — small label + percentage + thin bar +
///   reset time hint. Information-dense, low-attention.
/// - `time`: emphasize remaining time before reset, with a small ring
///   showing the percentage.
enum UsageBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case alert
    case compact
    case time

    var id: String { rawValue }
}

/// How fast the notch expands when the mouse hovers over it.
enum HoverSpeed: String, Codable, CaseIterable, Identifiable {
    case instant  // 0s — expand immediately
    case normal   // 1s delay (default)
    case slow     // 2s delay

    var id: String { rawValue }

    /// Delay in seconds before the notch expands on hover.
    var delay: TimeInterval {
        switch self {
        case .instant: return 0.0
        case .normal:  return 0.5
        case .slow:    return 1.0
        }
    }
}
