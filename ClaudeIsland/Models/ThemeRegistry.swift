//
//  ThemeRegistry.swift
//  ClaudeIsland
//
//  Central registry for built-in and plugin-provided notch themes.
//

import Combine
import Foundation

struct ThemeDescriptor: Equatable, Identifiable {
    let id: NotchThemeID
    let fallbackDisplayName: String
    let previewIdleLabelEN: String
    let previewIdleLabelZH: String
    let prefersUppercasePreviewLabel: Bool
    let tokens: ThemeTokens
    let source: ThemeSource

    enum ThemeSource: Equatable {
        case builtIn
        case plugin(pluginID: String)
        case file(path: String)
    }

    func previewIdleLabel(isChinese: Bool) -> String {
        isChinese ? previewIdleLabelZH : previewIdleLabelEN
    }
}

private struct ThemePluginManifest: Codable {
    let id: String
    let displayName: String
    let previewIdleLabelEN: String?
    let previewIdleLabelZH: String?
    let prefersUppercasePreviewLabel: Bool?
    let tokens: ThemeTokens
}

@MainActor
final class ThemeRegistry: ObservableObject {
    static let shared = ThemeRegistry()

    @Published private(set) var availableThemes: [ThemeDescriptor]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        self.availableThemes = Self.builtInDescriptors
        NativePluginManager.shared.$loadedPlugins
            .sink { [weak self] _ in
                self?.loadAll()
            }
            .store(in: &cancellables)
    }

    var themeIDs: [NotchThemeID] {
        availableThemes.map(\.id)
    }

    func descriptor(for id: NotchThemeID) -> ThemeDescriptor {
        availableThemes.first(where: { $0.id == id }) ?? Self.builtInDescriptors[0]
    }

    func displayName(for id: NotchThemeID) -> String {
        descriptor(for: id).fallbackDisplayName
    }

    func loadAll(pluginBundles: [Bundle]? = nil) {
        var descriptors = Self.builtInDescriptors
        var seen = Set(descriptors.map(\.id))
        let resolvedBundles = pluginBundles ?? NativePluginManager.shared.loadedPlugins.map(\.bundle)

        for descriptor in loadThemeFiles(in: userThemesDirectory(), source: .file(path: userThemesDirectory().path)) {
            guard !seen.contains(descriptor.id) else { continue }
            descriptors.append(descriptor)
            seen.insert(descriptor.id)
        }

        for bundle in resolvedBundles where bundle != Bundle.main {
            let source = ThemeDescriptor.ThemeSource.plugin(pluginID: bundle.bundleIdentifier ?? bundle.bundleURL.lastPathComponent)
            for descriptor in loadThemeFiles(in: bundle.bundleURL.appendingPathComponent("Contents/Resources/Themes"), source: source) {
                guard !seen.contains(descriptor.id) else { continue }
                descriptors.append(descriptor)
                seen.insert(descriptor.id)
            }
        }

        availableThemes = descriptors
    }

    private func loadThemeFiles(in directory: URL, source: ThemeDescriptor.ThemeSource) -> [ThemeDescriptor] {
        guard FileManager.default.fileExists(atPath: directory.path),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? decoder.decode(ThemePluginManifest.self, from: data) else {
                    return nil
                }
                return ThemeDescriptor(
                    id: NotchThemeID(rawValue: manifest.id),
                    fallbackDisplayName: manifest.displayName,
                    previewIdleLabelEN: manifest.previewIdleLabelEN ?? "Idle",
                    previewIdleLabelZH: manifest.previewIdleLabelZH ?? "空闲",
                    prefersUppercasePreviewLabel: manifest.prefersUppercasePreviewLabel ?? false,
                    tokens: manifest.tokens,
                    source: source
                )
            }
    }

    private func userThemesDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/codeisland/themes")
    }

    static let builtInDescriptors: [ThemeDescriptor] = [
        ThemeDescriptor(
            id: .classic,
            fallbackDisplayName: "Classic",
            previewIdleLabelEN: "Idle",
            previewIdleLabelZH: "空闲",
            prefersUppercasePreviewLabel: false,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "0A0A0B"), overlay: .init(hex: "191919"), border: .init(hex: "2A2A2C")),
                text: .init(primary: .init(hex: "EDEDEE"), secondary: .init(hex: "C7C7CB"), muted: .init(hex: "8B8B90"), inverse: .init(hex: "0A0A0B")),
                status: .init(idle: .init(hex: "CCFF00"), working: .init(hex: "67E8F9"), needsYou: .init(hex: "FBBF24"), error: .init(hex: "F87171"), done: .init(hex: "4ADE80"), thinking: .init(hex: "B794F6")),
                badges: .init(agentText: .init(hex: "7DB4FF"), agentFill: .init(hex: "1E3A8A"), terminalText: .init(hex: "A8CBFF"), terminalFill: .init(hex: "1E3A8A"), subduedText: .init(hex: "E8E8EA"), subduedFill: .init(hex: "242428")),
                usage: .init(text: .init(hex: "F4F4F5"), track: .init(hex: "26262A"), fill: .init(hex: "A3E635"), border: .init(hex: "2A2A2C")),
                chat: .init(bodyText: .init(hex: "EDEDEE"), secondaryText: .init(hex: "B8B8BD"), bubbleText: .init(hex: "F4F4F5"), bubbleFill: .init(hex: "2E2E32"), assistantDot: .init(hex: "EDEDEE"))
            ),
            source: .builtIn
        ),
        ThemeDescriptor(
            id: .forest,
            fallbackDisplayName: "Forest",
            previewIdleLabelEN: "Idle",
            previewIdleLabelZH: "空闲",
            prefersUppercasePreviewLabel: false,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "0A1C12"), overlay: .init(hex: "122B1C"), border: .init(hex: "2B4A37")),
                text: .init(primary: .init(hex: "EAF6EB"), secondary: .init(hex: "B9D3C0"), muted: .init(hex: "8DAC98"), inverse: .init(hex: "07120B")),
                status: .init(idle: .init(hex: "86D957"), working: .init(hex: "5BE0D8"), needsYou: .init(hex: "F5A524"), error: .init(hex: "F0584F"), done: .init(hex: "50DF82"), thinking: .init(hex: "A78BFA")),
                badges: .init(agentText: .init(hex: "D4ECDB"), agentFill: .init(hex: "224A30"), terminalText: .init(hex: "A9DEB8"), terminalFill: .init(hex: "173220"), subduedText: .init(hex: "D7E8DC"), subduedFill: .init(hex: "173220")),
                usage: .init(text: .init(hex: "DDEFE2"), track: .init(hex: "2A4937"), fill: .init(hex: "86D957"), border: .init(hex: "2A4937")),
                chat: .init(bodyText: .init(hex: "EAF6EB"), secondaryText: .init(hex: "B9D3C0"), bubbleText: .init(hex: "EAF6EB"), bubbleFill: .init(hex: "224A30"), assistantDot: .init(hex: "D4ECDB"))
            ),
            source: .builtIn
        ),
        ThemeDescriptor(
            id: .neonTokyo,
            fallbackDisplayName: "Night Circuit",
            previewIdleLabelEN: "IDLE_",
            previewIdleLabelZH: "IDLE_",
            prefersUppercasePreviewLabel: true,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "04060F"), overlay: .init(hex: "0E1530"), border: .init(hex: "23306B")),
                text: .init(primary: .init(hex: "F8F4FF"), secondary: .init(hex: "C9B8FF"), muted: .init(hex: "7FA8E0"), inverse: .init(hex: "000000")),
                status: .init(idle: .init(hex: "FF1FB0"), working: .init(hex: "1FF0FF"), needsYou: .init(hex: "FFB300"), error: .init(hex: "FF3D5E"), done: .init(hex: "5CF2C0"), thinking: .init(hex: "A36BFF")),
                badges: .init(agentText: .init(hex: "FF8FD4"), agentFill: .init(hex: "2B0F4A"), terminalText: .init(hex: "7DF6FF"), terminalFill: .init(hex: "06304C"), subduedText: .init(hex: "DCD0FF"), subduedFill: .init(hex: "141F4A")),
                usage: .init(text: .init(hex: "EBE2FF"), track: .init(hex: "17244A"), fill: .init(hex: "FF1FB0"), border: .init(hex: "2A3D78")),
                chat: .init(bodyText: .init(hex: "F8F4FF"), secondaryText: .init(hex: "C9B8FF"), bubbleText: .init(hex: "F8F4FF"), bubbleFill: .init(hex: "121A3D"), assistantDot: .init(hex: "1FF0FF"))
            ),
            source: .builtIn
        ),
        ThemeDescriptor(
            id: .sunset,
            fallbackDisplayName: "Sunset",
            previewIdleLabelEN: "At rest",
            previewIdleLabelZH: "静候",
            prefersUppercasePreviewLabel: false,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "FFEFDC"), overlay: .init(hex: "FBE0C6"), border: .init(hex: "EDC9A8")),
                text: .init(primary: .init(hex: "47210F"), secondary: .init(hex: "6B3C25"), muted: .init(hex: "9C5E3F"), inverse: .init(hex: "FFFFFF")),
                status: .init(idle: .init(hex: "D9491E"), working: .init(hex: "0E7C6E"), needsYou: .init(hex: "A85A06"), error: .init(hex: "AE1A1A"), done: .init(hex: "197A38"), thinking: .init(hex: "8B3FD6")),
                badges: .init(agentText: .init(hex: "7A2E10"), agentFill: .init(hex: "FAD2B0"), terminalText: .init(hex: "53382A"), terminalFill: .init(hex: "F4DBC4"), subduedText: .init(hex: "53382A"), subduedFill: .init(hex: "F4DBC4")),
                usage: .init(text: .init(hex: "47210F"), track: .init(hex: "EDC9A8"), fill: .init(hex: "D9491E"), border: .init(hex: "EDC9A8")),
                chat: .init(bodyText: .init(hex: "47210F"), secondaryText: .init(hex: "6B3C25"), bubbleText: .init(hex: "47210F"), bubbleFill: .init(hex: "FBE0C6"), assistantDot: .init(hex: "D9491E"))
            ),
            source: .builtIn
        ),
        ThemeDescriptor(
            id: .retroArcade,
            fallbackDisplayName: "Retro Arcade",
            previewIdleLabelEN: "IDLE",
            previewIdleLabelZH: "IDLE",
            prefersUppercasePreviewLabel: true,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "34C77B"), overlay: .init(hex: "6FE0A8"), border: .init(hex: "0B5138")),
                text: .init(primary: .init(hex: "0C2E1E"), secondary: .init(hex: "124A30"), muted: .init(hex: "18583A"), inverse: .init(hex: "FFFFFF")),
                status: .init(idle: .init(hex: "064E3B"), working: .init(hex: "0B5138"), needsYou: .init(hex: "8A4B0E"), error: .init(hex: "A01818"), done: .init(hex: "117A3D"), thinking: .init(hex: "3B2E91")),
                badges: .init(agentText: .init(hex: "0C2E1E"), agentFill: .init(hex: "9DEFC4"), terminalText: .init(hex: "0C2E1E"), terminalFill: .init(hex: "6FE0A8"), subduedText: .init(hex: "0C2E1E"), subduedFill: .init(hex: "7FE8B4")),
                usage: .init(text: .init(hex: "0C2E1E"), track: .init(hex: "9DEFC4"), fill: .init(hex: "064E3B"), border: .init(hex: "0B5138")),
                chat: .init(bodyText: .init(hex: "0C2E1E"), secondaryText: .init(hex: "124A30"), bubbleText: .init(hex: "0C2E1E"), bubbleFill: .init(hex: "9DEFC4"), assistantDot: .init(hex: "064E3B"))
            ),
            source: .builtIn
        ),
        ThemeDescriptor(
            id: .highContrast,
            fallbackDisplayName: "High Contrast",
            previewIdleLabelEN: "Idle",
            previewIdleLabelZH: "空闲",
            prefersUppercasePreviewLabel: false,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "000000"), overlay: .init(hex: "121212"), border: .init(hex: "FFFFFF")),
                text: .init(primary: .init(hex: "FFFFFF"), secondary: .init(hex: "E6E6E6"), muted: .init(hex: "BFBFBF"), inverse: .init(hex: "000000")),
                status: .init(idle: .init(hex: "FFD400"), working: .init(hex: "5EE7F5"), needsYou: .init(hex: "FFA51F"), error: .init(hex: "FF5C57"), done: .init(hex: "3DE07A"), thinking: .init(hex: "B695FF")),
                badges: .init(agentText: .init(hex: "FFFFFF"), agentFill: .init(hex: "000000"), terminalText: .init(hex: "FFFFFF"), terminalFill: .init(hex: "000000"), subduedText: .init(hex: "FFFFFF"), subduedFill: .init(hex: "000000")),
                usage: .init(text: .init(hex: "FFFFFF"), track: .init(hex: "333333"), fill: .init(hex: "FFD400"), border: .init(hex: "FFFFFF")),
                chat: .init(bodyText: .init(hex: "FFFFFF"), secondaryText: .init(hex: "C9C9C9"), bubbleText: .init(hex: "FFFFFF"), bubbleFill: .init(hex: "161616"), assistantDot: .init(hex: "FFD400"))
            ),
            source: .builtIn
        ),
        ThemeDescriptor(
            id: .sakura,
            fallbackDisplayName: "Pink Mist",
            previewIdleLabelEN: "Resting",
            previewIdleLabelZH: "小憩",
            prefersUppercasePreviewLabel: false,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "FDF2F8"), overlay: .init(hex: "FCE0EE"), border: .init(hex: "F3BBD6")),
                text: .init(primary: .init(hex: "6E2C4E"), secondary: .init(hex: "9A4A74"), muted: .init(hex: "B06A92"), inverse: .init(hex: "FFFFFF")),
                status: .init(idle: .init(hex: "DB2777"), working: .init(hex: "F9A8D4"), needsYou: .init(hex: "D98324"), error: .init(hex: "D6395C"), done: .init(hex: "2E9E6E"), thinking: .init(hex: "B266E0")),
                badges: .init(agentText: .init(hex: "8A2F5C"), agentFill: .init(hex: "FBD0E6"), terminalText: .init(hex: "6E2C4E"), terminalFill: .init(hex: "FDEAF4"), subduedText: .init(hex: "6E2C4E"), subduedFill: .init(hex: "FBE2F0")),
                usage: .init(text: .init(hex: "6E2C4E"), track: .init(hex: "F7C9DF"), fill: .init(hex: "DB2777"), border: .init(hex: "F0B4D0")),
                chat: .init(bodyText: .init(hex: "6E2C4E"), secondaryText: .init(hex: "9A4A74"), bubbleText: .init(hex: "6E2C4E"), bubbleFill: .init(hex: "FDEAF4"), assistantDot: .init(hex: "DB2777"))
            ),
            source: .builtIn
        ),
        ThemeDescriptor(
            id: .catppuccin,
            fallbackDisplayName: "Catppuccin",
            previewIdleLabelEN: "purring",
            previewIdleLabelZH: "打盹",
            prefersUppercasePreviewLabel: false,
            tokens: ThemeTokens(
                chrome: .init(background: .init(hex: "1E1E2E"), overlay: .init(hex: "313244"), border: .init(hex: "45475A")),
                text: .init(primary: .init(hex: "CDD6F4"), secondary: .init(hex: "BAC2DE"), muted: .init(hex: "7F849C"), inverse: .init(hex: "11111B")),
                status: .init(idle: .init(hex: "CBA6F7"), working: .init(hex: "89DCEB"), needsYou: .init(hex: "FAB387"), error: .init(hex: "F38BA8"), done: .init(hex: "A6E3A1"), thinking: .init(hex: "B4BEFE")),
                badges: .init(agentText: .init(hex: "89B4FA"), agentFill: .init(hex: "313244"), terminalText: .init(hex: "94E2D5"), terminalFill: .init(hex: "313244"), subduedText: .init(hex: "A6ADC8"), subduedFill: .init(hex: "45475A")),
                usage: .init(text: .init(hex: "CDD6F4"), track: .init(hex: "45475A"), fill: .init(hex: "A6E3A1"), border: .init(hex: "45475A")),
                chat: .init(bodyText: .init(hex: "CDD6F4"), secondaryText: .init(hex: "BAC2DE"), bubbleText: .init(hex: "CDD6F4"), bubbleFill: .init(hex: "313244"), assistantDot: .init(hex: "CBA6F7"))
            ),
            source: .builtIn
        ),
    ]
}
