//
//  SystemSettingsView.swift
//  ClaudeIsland
//
//  Floating "System Settings" window — the single home for every
//  configuration surface that used to crowd the notch menu or open its
//  own one-off popup (Launch Presets included).
//
//  Layout: vertical sidebar on the left (tab list), detail view on the
//  right. Designed to scale to many more tabs as config grows — add
//  a new case to `SettingsTab`, a new content view, and a single line
//  in the dispatcher.
//
//  Theme: solid brand lime (#CAFF00) surface with near-black text,
//  matching the Pair phone QR popup.
//

import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

private func settingsTheme() -> ThemeResolver {
    ThemeResolver(theme: NotchCustomizationStore.shared.customization.theme)
}

// MARK: - Notch menu entry row

struct SystemSettingsRow: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            SystemSettingsWindow.shared.show()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .opacity(isHovered ? 1 : 0.6)
                    .frame(width: 16)

                Text(L10n.openSettings)
                    .font(.system(size: 13, weight: .medium))
                    .opacity(isHovered ? 1 : 0.7)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(0.3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Theme.sidebarActiveFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Floating Window

/// Borderless NSWindows return `false` from `canBecomeKey` by default,
/// which blocks SwiftUI TextFields inside them from receiving keyboard
/// focus. Overriding this lets text inputs (e.g. the Anthropic API Proxy
/// field) accept typing. Mirrors the pattern in PairPhoneView.swift.
private final class KeyableSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Called to close the window (e.g. by Cmd+W via main-menu File→Close).
    /// Borderless windows don't get this for free, and Mio Island is an
    /// accessory app with no main menu anyway, so we also intercept Cmd+W
    /// in keyDown below. Both paths funnel through here.
    override func performClose(_ sender: Any?) {
        close()
    }

    /// Intercept Cmd+W at the window level. In a normal app Cmd+W routes
    /// through File→Close Window in the main menu, but Mio Island runs
    /// as an accessory (no main menu), so the shortcut otherwise beeps.
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class SystemSettingsWindow {
    static let shared = SystemSettingsWindow()

    private var window: NSWindow?

    func show(initialTab: SettingsTab = .general) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SystemSettingsContentView(
            initialTab: initialTab,
            onClose: { self.close() },
            onHide: { self.hide() }
        )
        let hostingView = NSHostingView(rootView: contentView)
        let w = KeyableSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.contentView = hostingView
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 16
        w.contentView?.layer?.masksToBounds = true

        if let screen = NSScreen.main {
            let f = screen.frame
            w.setFrameOrigin(NSPoint(x: f.midX - 480, y: f.midY - 360))
        }

        // Keep at normal window level: the settings pane is a regular
        // workspace, not a HUD. Users want it to sit below other apps when
        // they focus elsewhere, not to float on top of everything. The
        // previous `.maximumWindow` level made it shadow the entire OS.
        w.level = .normal
        NSApplication.shared.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.isReleasedWhenClosed = false
        self.window = w
    }

    func close() {
        window?.close()
        window = nil
    }

    /// Hide the window without destroying it — next `show()` re-foregrounds the
    /// same instance (state preserved). Used by the titlebar minimize button;
    /// borderless windows can't `miniaturize` to the Dock, so we `orderOut`.
    func hide() {
        window?.orderOut(nil)
    }
}

// MARK: - Tab enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case notifications
    case behavior
    case plugins
    case codelight       // Pair iPhone + Launch Presets merged
    case cmuxConnection  // diagnostics for phone→terminal relay
    case logs            // live DebugLogger tail
    case advanced
    case about

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:        return "gearshape.fill"
        case .appearance:     return "paintbrush.fill"
        case .notifications:  return "bell.badge.fill"
        case .behavior:       return "slider.horizontal.3"
        case .plugins:        return "puzzlepiece.extension.fill"
        case .codelight:      return "iphone.radiowaves.left.and.right"
        case .cmuxConnection: return "terminal.fill"
        case .logs:           return "doc.text.magnifyingglass"
        case .advanced:       return "wrench.and.screwdriver.fill"
        case .about:          return "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .general:        return L10n.tabGeneral
        case .appearance:     return L10n.tabAppearance
        case .notifications:  return L10n.tabNotifications
        case .behavior:       return L10n.tabBehavior
        case .plugins:        return "Plugins"
        case .codelight:      return L10n.tabCodeLight
        case .cmuxConnection: return L10n.tabCmuxConnection
        case .logs:           return L10n.tabLogs
        case .advanced:       return L10n.tabAdvanced
        case .about:          return L10n.tabAbout
        }
    }

    /// English subtitle shown next to the Chinese H1 on each detail pane —
    /// mirrors the reference mock's "通用  General preferences" pattern.
    /// When the UI is already English, we skip it to avoid duplicating the title.
    var englishSubtitle: String {
        guard L10n.isChinese else { return "" }
        switch self {
        case .general:        return "General preferences"
        case .appearance:     return "Appearance"
        case .notifications:  return "Notifications"
        case .behavior:       return "Behavior"
        case .plugins:        return "Plugins & Extensions"
        case .codelight:      return "CodeLight"
        case .cmuxConnection: return "cmux Connection"
        case .logs:           return "Logs"
        case .advanced:       return "Advanced"
        case .about:          return "About"
        }
    }
}

// MARK: - Shared theming constants

/// Graphite two-surface theme: sidebar is a warm charcoal (`#201f27`),
/// detail area is a slightly darker graphite (`#1c1c1e`). Lime survives
/// only as an accent on toggles, active sidebar icons, and focus rings.
/// Palette is lifted from the Anthropic-style reference design — see
/// `~/Desktop/1_files/UI.jsx` and the System Settings HTML mock.
enum Theme {
    private static var resolver: ThemeResolver { settingsTheme() }

    // Sidebar / detail surfaces now derive from the global semantic theme.
    static var sidebarFill: Color { resolver.overlay.opacity(resolver.isRetroArcade ? 0.92 : 0.94) }
    static var sidebarText: Color { resolver.primaryText }
    static var sidebarActiveFill: Color { resolver.primaryText.opacity(resolver.isRetroArcade ? 0.12 : 0.08) }
    static var sidebarHoverFill: Color { resolver.primaryText.opacity(resolver.isRetroArcade ? 0.08 : 0.04) }
    static var sidebarBorder: Color { resolver.border.opacity(resolver.isRetroArcade ? 0.3 : 0.16) }

    static var detailFill: Color { resolver.background }
    static var detailText: Color { resolver.primaryText }
    static var border: Color { resolver.border }

    static var cardFill: Color { resolver.overlay.opacity(resolver.isRetroArcade ? 0.18 : 0.32) }
    static var cardBorder: Color { resolver.border.opacity(resolver.isRetroArcade ? 0.32 : 0.22) }
    static var rowDivider: Color { resolver.border.opacity(resolver.isRetroArcade ? 0.22 : 0.16) }
    static var subtle: Color { resolver.mutedText }
    static var subtleStrong: Color { resolver.secondaryText }

    // Accent now follows semantic working/done emphasis instead of a fixed lime.
    static var accent: Color { resolver.doneColor }
    static var controlFill: Color { resolver.overlay.opacity(resolver.isRetroArcade ? 0.14 : 0.18) }
    static var controlBorder: Color { resolver.border.opacity(resolver.isRetroArcade ? 0.28 : 0.22) }
    static var iconTileFill: Color { resolver.overlay.opacity(resolver.isRetroArcade ? 0.16 : 0.18) }
    static var iconTileBorder: Color { resolver.border.opacity(resolver.isRetroArcade ? 0.28 : 0.22) }
    static var fieldFill: Color { resolver.overlay.opacity(resolver.isRetroArcade ? 0.22 : 0.44) }
    static var fieldBorder: Color { resolver.border.opacity(resolver.isRetroArcade ? 0.34 : 0.28) }
    static var placeholder: Color { resolver.mutedText.opacity(0.9) }
    static var shadow: Color { Color.black.opacity(resolver.isRetroArcade ? 0.22 : 0.5) }
    static var destructiveText: Color { resolver.errorColor }
    static var destructiveFill: Color { resolver.errorColor.opacity(0.1) }
    static var destructiveBorder: Color { resolver.errorColor.opacity(0.18) }
    static var success: Color { resolver.doneColor }
    static var warning: Color { resolver.needsYouColor }
    static var error: Color { resolver.errorColor }
    static var neutralDot: Color { resolver.mutedText.opacity(0.5) }
    static var backgroundInk: Color { resolver.inverseText }
    static var titlebarGlyph: Color { resolver.inverseText.opacity(0.6) }
    static var knobShadow: Color { Color.black.opacity(resolver.isRetroArcade ? 0.18 : 0.35) }
    static var toggleActiveBorder: Color { resolver.inverseText.opacity(0.25) }

    // Real macOS traffic-light colors.
    static let tlRed = Color(red: 1.00, green: 0.373, blue: 0.341)
    static let tlYellow = Color(red: 0.996, green: 0.737, blue: 0.180)
    static let tlGreen = Color(red: 0.157, green: 0.784, blue: 0.251)
    static let tlStroke = Color.black.opacity(0.25)
}

// MARK: - Content root

private struct SystemSettingsContentView: View {
    let initialTab: SettingsTab
    let onClose: () -> Void
    let onHide: () -> Void
    @State private var tab: SettingsTab
    @State private var isHoveringTitleBar = false
    /// Observe the theme store so swapping themes re-renders the whole
    /// settings tree. Without this subscription the body only references
    /// `Theme.*` (a static enum that reads from the store each call),
    /// so SwiftUI has no dependency edge and skips invalidation — users
    /// had to click a sidebar tab to force a re-render.
    @ObservedObject private var notchStore = NotchCustomizationStore.shared

    init(
        initialTab: SettingsTab = .general,
        onClose: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        self.initialTab = initialTab
        self.onClose = onClose
        self.onHide = onHide
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        // IMPORTANT: clipShape BEFORE overlay so the rounded corners actually
        // cut the sidebar's opaque lime fill and the detail's dark fill,
        // then the overlay border is stroked on the clipped edge on top.
        // Putting shadow OUTSIDE the clip so it isn't cut off.
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                sidebar
                detail
            }
        }
        .frame(width: 960, height: 720)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: Theme.shadow, radius: 30, y: 12)
        .onHover { isHoveringTitleBar = $0 }
    }

    // MARK: Title bar

    /// Real macOS-style chrome: red/yellow/green dots on the left, centered
    /// title. Borderless windows have no OS chrome, so we synthesize it.
    private var titleBar: some View {
        ZStack {
            HStack(spacing: 8) {
                trafficLight(fill: Theme.tlRed, glyph: "xmark", action: onClose)
                trafficLight(fill: Theme.tlYellow, glyph: "minus", action: onHide)
                // Green is decorative (no fullscreen for a utility window).
                Circle()
                    .fill(Theme.tlGreen)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Theme.tlStroke, lineWidth: 0.5))
                Spacer()
            }
            .padding(.horizontal, 14)

            Text(L10n.systemSettings)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.detailText.opacity(0.85))
        }
        .frame(height: 38)
        .background(Theme.sidebarFill)
        .overlay(
            Rectangle()
                .fill(Theme.border)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func trafficLight(fill: Color, glyph: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 12, height: 12)
                .overlay(
                    Image(systemName: glyph)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(Theme.titlebarGlyph.opacity(isHoveringTitleBar ? 1 : 0))
                )
                .overlay(Circle().strokeBorder(Theme.tlStroke, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 10)
            ForEach(SettingsTab.allCases) { t in
                tabRow(t)
            }

            Spacer()

            Rectangle()
                .fill(Theme.rowDivider)
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.subtle)
                        .frame(width: 18)
                    Text(L10n.isChinese ? "退出" : "Quit")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.subtleStrong)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 196)
        .background(Theme.sidebarFill)
        .overlay(
            Rectangle()
                .fill(Theme.sidebarBorder)
                .frame(width: 0.5),
            alignment: .trailing
        )
    }

    @ViewBuilder
    private func tabRow(_ t: SettingsTab) -> some View {
        let isSelected = tab == t
        SidebarPillRow(
            icon: t.icon,
            label: t.label,
            isSelected: isSelected,
            action: {
                withAnimation(.easeOut(duration: 0.15)) { tab = t }
            }
        )
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // Large H1 + English subtitle, mirroring the reference mock.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(tab.label)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(Theme.detailText)
                        .tracking(-0.4)
                    Text(tab.englishSubtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.subtle)
                }
                .padding(.top, 22)
                .padding(.bottom, 4)

                switch tab {
                case .general:        GeneralTab()
                case .appearance:     AppearanceTab()
                case .notifications:  NotificationsTab()
                case .behavior:       BehaviorTab()
                case .plugins:        NativePluginStoreView()
                case .codelight:      CodeLightTab()
                case .cmuxConnection: CmuxConnectionTab()
                case .logs:           LogsTab()
                case .advanced:       AdvancedTab()
                case .about:          AboutTab()
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.detailFill)
    }
}

// MARK: - Reusable tab-level primitives

/// Sidebar pill: hover = subtle fill, active = slightly stronger fill + lime
/// icon. Hoisted out of the content view so we can hold per-row hover state.
private struct SidebarPillRow: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? Theme.accent : Theme.subtle)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Theme.detailText : Theme.subtleStrong)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? Theme.sidebarActiveFill
                          : (isHovered ? Theme.sidebarHoverFill : Color.clear))
            )
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Card container. Reference design uses `rgba(255,255,255,0.03)` fill +
/// `rgba(255,255,255,0.08)` border at radius 12. The optional uppercase
/// "section label" now renders *above* the card, not inside it.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundColor(Theme.subtle)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                    )
            )
        }
    }
}

/// iOS-style pill toggle matching the reference mock: neon-lime gradient
/// when on, inset charcoal when off, with a radial-highlight knob that
/// animates between ends.
private struct IOSToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.87)],
                        startPoint: .top, endPoint: .bottom
                    )) : AnyShapeStyle(Theme.controlFill))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isOn ? Theme.toggleActiveBorder : Theme.controlBorder,
                                lineWidth: 0.5
                            )
                    )
                    .shadow(
                        color: isOn ? Theme.accent.opacity(0.3) : .clear,
                        radius: 6, y: 2
                    )

                Circle()
                    .fill(RadialGradient(
                        colors: [Color.white, Color(white: 0.95), Color(white: 0.88)],
                        center: UnitPoint(x: 0.4, y: 0.35),
                        startRadius: 0, endRadius: 14
                    ))
                    .frame(width: 19, height: 19)
                    .shadow(color: Theme.knobShadow, radius: 1.5, y: 1)
                    .padding(2)
            }
            .frame(width: 38, height: 23)
            .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// Toggle cell — icon tile + label + iOS slider. Adopts the reference
/// "setting row" pattern (icon square, main label, optional sublabel).
private struct TabToggle: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.iconTileFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.iconTileBorder, lineWidth: 0.5)
                    )
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(isOn ? Theme.accent : Theme.subtleStrong)
            }
            .frame(width: 28, height: 28)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.detailText.opacity(0.92))

            Spacer(minLength: 0)

            IOSToggle(isOn: isOn, action: action)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Reference-style list-of-rows primitives

/// Section label above a card: uppercase, tracked, muted.
/// Usage: `SectionLabel(L10n.someSection)` then `SettingsListCard { ... }`.
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundColor(Theme.subtle)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }
}

/// Card sized for a vertical list of SettingRow. Uses tight vertical padding
/// so rows' own 12pt vertical padding drives the row height — matches the
/// reference mock's `padding: '4px 16px'` row card.
private struct SettingsListCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
        )
    }
}

/// A single list row: optional icon tile, label, optional sublabel, control.
/// `isLast` suppresses the bottom divider so the final row sits flush with the
/// card's bottom padding.
private struct SettingRow<Control: View>: View {
    let icon: String?
    let label: String
    let sublabel: String?
    let isLast: Bool
    @ViewBuilder let control: () -> Control

    init(
        icon: String? = nil,
        label: String,
        sublabel: String? = nil,
        isLast: Bool = false,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.icon = icon
        self.label = label
        self.sublabel = sublabel
        self.isLast = isLast
        self.control = control
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.iconTileFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.iconTileBorder, lineWidth: 0.5)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.subtleStrong)
                }
                .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.detailText.opacity(0.92))
                if let sublabel, !sublabel.isEmpty {
                    Text(sublabel)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.subtle)
                }
            }

            Spacer(minLength: 8)

            control()
        }
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(Theme.rowDivider)
                .frame(height: 0.5)
                .opacity(isLast ? 0 : 1),
            alignment: .bottom
        )
    }
}

/// Colored dot + title + body, used in the proxy explanation card.
/// `variant` controls dot color + glyph:
///   - .pos  → accent-filled, "✓"
///   - .neg  → muted outline, "✕"
///   - .hint → muted outline, "i"
private struct InfoRow: View {
    enum Variant { case pos, neg, hint }
    let variant: Variant
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dot
            (Text(title + "：")
                .foregroundColor(Theme.detailText.opacity(0.9))
                .font(.system(size: 12, weight: .medium))
             + Text(message)
                .foregroundColor(Theme.subtleStrong)
                .font(.system(size: 12)))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var dot: some View {
        let isPos = variant == .pos
        ZStack {
            Circle()
                .fill(isPos ? Theme.accent : Theme.controlFill)
                .overlay(
                    Circle().strokeBorder(
                        isPos ? Color.clear : Theme.controlBorder,
                        lineWidth: 0.5
                    )
                )
            Text(glyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isPos ? Theme.backgroundInk : Theme.subtleStrong)
        }
        .frame(width: 16, height: 16)
        .padding(.top, 1)
    }

    private var glyph: String {
        switch variant {
        case .pos: return "✓"
        case .neg: return "✕"
        case .hint: return "i"
        }
    }
}

// MARK: - General tab

private struct GeneralTab: View {
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ObservedObject private var codexGate = CodexFeatureGate.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Quick toggles — vertical list with dividers, sublabels for each.
            SectionLabel(L10n.isChinese ? "快速开关" : "Quick Toggles")
            SettingsListCard {
                SettingRow(
                    icon: "power",
                    label: L10n.launchAtLogin,
                    sublabel: L10n.isChinese
                        ? "系统登录时自动运行 MioIsland"
                        : "Run MioIsland automatically at login"
                ) {
                    IOSToggle(isOn: launchAtLogin) {
                        do {
                            if launchAtLogin {
                                try SMAppService.mainApp.unregister()
                                launchAtLogin = false
                            } else {
                                try SMAppService.mainApp.register()
                                launchAtLogin = true
                            }
                        } catch {}
                    }
                }
                SettingRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: L10n.hooks,
                    sublabel: L10n.isChinese
                        ? "拦截与注入 Claude CLI 生命周期"
                        : "Intercept and instrument the Claude CLI lifecycle"
                ) {
                    IOSToggle(isOn: hooksInstalled) {
                        if hooksInstalled {
                            HookInstaller.uninstall()
                            hooksInstalled = false
                        } else {
                            HookInstaller.installIfNeeded()
                            hooksInstalled = true
                        }
                    }
                }
                SettingRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: L10n.codexSupport,
                    sublabel: L10n.isChinese
                        ? "启用 Codex CLI 辅助与代码建议"
                        : "Enable Codex CLI assistance and code suggestions",
                    isLast: true
                ) {
                    IOSToggle(isOn: codexGate.isEnabled) {
                        codexGate.isEnabled.toggle()
                    }
                }
            }

            // Proxy
            SectionLabel(L10n.anthropicApiProxy)
            AnthropicProxyRow()

            // Language
            SectionLabel(L10n.language)
            SettingsListCard {
                SettingsLanguageRow(isLast: true)
            }

            // Accessibility
            SectionLabel(L10n.accessibility)
            SettingsListCard {
                SettingsAccessibilityRow(isLast: true)
            }

            // Hidden projects (cwd blacklist)
            SectionLabel(L10n.isChinese ? "隐藏的项目" : "Hidden Projects")
            HiddenProjectsCard()
        }
    }
}

/// Lists user-blacklisted project cwds with per-row unblacklist + clear-all.
private struct HiddenProjectsCard: View {
    @ObservedObject private var hidden: HiddenProjectsStore = .shared

    var body: some View {
        SettingsListCard {
            if hidden.allBlacklisted.isEmpty {
                HStack {
                    Text(L10n.isChinese
                         ? "暂无隐藏的项目。在通知中心列表中右键或悬停项目分组可隐藏它们。"
                         : "No hidden projects. Right-click or hover a group in the list to hide it.")
                        .notchFont(11)
                        .notchSecondaryForeground()
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            } else {
                ForEach(Array(hidden.allBlacklisted.enumerated()), id: \.element) { idx, cwd in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: cwd).lastPathComponent)
                                .notchFont(13, weight: .medium)
                            Text(cwd)
                                .notchFont(11)
                                .notchSecondaryForeground()
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(L10n.isChinese ? "取消隐藏" : "Unhide") {
                            hidden.unblacklist(cwd: cwd)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    if idx < hidden.allBlacklisted.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
                Divider().opacity(0.4)
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        hidden.clearAll()
                    } label: {
                        Text(L10n.isChinese ? "清空全部" : "Clear All")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }
}

/// Proxy input + three "作用于 / 不作用于 / 留空即直连" info rows.
/// Replaces the old single-paragraph description with the structured
/// ✓ / ✕ / i rows from the reference mock.
private struct AnthropicProxyRow: View {
    @AppStorage("anthropicProxyURL") private var proxyURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // SwiftUI's TextField.prompt repeatedly ignores `foregroundColor`
            // on macOS and falls back to its own secondary-label gray, which
            // reads almost-black on our dark input fill. Roll our own: a
            // manually positioned Text, only visible when empty, in a solid
            // light gray we control.
            ZStack(alignment: .leading) {
                if proxyURL.isEmpty {
                    Text(L10n.anthropicApiProxyPlaceholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.placeholder)
                        .padding(.horizontal, 12)
                        .allowsHitTesting(false)
                }
                TextField("", text: $proxyURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.detailText.opacity(0.95))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.fieldBorder, lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 9) {
                InfoRow(
                    variant: .pos,
                    title: L10n.isChinese ? "作用于" : "Applies to",
                    message: L10n.isChinese
                        ? "刘海额度条 (api.anthropic.com) 与 MioIsland 启动的所有子进程，包括 Stats 插件的 claude CLI。启动时设置一次 HTTPS_PROXY / HTTP_PROXY / ALL_PROXY，子进程自动继承。"
                        : "Notch usage bar (api.anthropic.com) and every subprocess spawned by MioIsland, including the Stats plugin's claude CLI. HTTPS_PROXY / HTTP_PROXY / ALL_PROXY are set once at launch and inherited."
                )
                InfoRow(
                    variant: .neg,
                    title: L10n.isChinese ? "不作用于" : "Does not apply to",
                    message: L10n.isChinese
                        ? "CodeLight 同步（始终直连）、第三方插件的 URLSession 调用（走系统代理）。"
                        : "CodeLight sync (always direct) and third-party plugin URLSession calls (use system proxy)."
                )
                InfoRow(
                    variant: .hint,
                    title: L10n.isChinese ? "留空即直连" : "Leave empty to disable",
                    message: L10n.isChinese
                        ? "无需配置代理时清空此字段即可。"
                        : "Clear this field when you don't need a proxy."
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
        )
    }
}

/// Settings-tab version of the language picker. The notch-menu version
/// (LanguageRow in NotchMenuView.swift) expands inline; here we use a
/// right-aligned Menu so it matches the reference's compact dropdown.
private struct SettingsLanguageRow: View {
    let isLast: Bool
    @State private var current = L10n.appLanguage

    private let options: [(id: String, label: String)] = [
        ("auto", "Auto / 自动"),
        ("zh", "简体中文"),
        ("en", "English"),
    ]

    private var currentLabel: String {
        options.first(where: { $0.id == current })?.label ?? "Auto"
    }

    var body: some View {
        SettingRow(
            icon: "globe",
            label: L10n.language,
            sublabel: L10n.isChinese
                ? "更改后重启应用生效"
                : "Restart the app for changes to take effect",
            isLast: isLast
        ) {
            Menu {
                ForEach(options, id: \.id) { option in
                    Button(option.label) {
                        L10n.appLanguage = option.id
                        current = option.id
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(currentLabel)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.detailText.opacity(0.85))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.subtle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Settings-tab accessibility row: icon + label + sublabel + status pill
/// (green dot + "已启用" when granted, "修复" button when not).
private struct SettingsAccessibilityRow: View {
    let isLast: Bool
    @State private var isGranted = AXIsProcessTrusted()
    @State private var isRepairing = false

    var body: some View {
        SettingRow(
            icon: "hand.raised.fill",
            label: L10n.accessibility,
            sublabel: L10n.isChinese
                ? "键盘快捷键与窗口控制需要此权限"
                : "Required for keyboard shortcuts and window control",
            isLast: isLast
        ) {
            if isGranted {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text(L10n.enabled)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.subtle)
                }
            } else {
                HStack(spacing: 6) {
                    // 主操作：一键修复（对付 ad-hoc 签名 CDHash 变化导致的 TCC 失效）
                    Button {
                        repair()
                    } label: {
                        Text(isRepairing ? L10n.repairing : L10n.repairPermission)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.backgroundInk)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRepairing)

                    // 备用：打开系统设置（老行为）
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help(L10n.openAccessibilitySettings)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isGranted = AXIsProcessTrusted()
        }
    }

    private func repair() {
        isRepairing = true
        Task {
            await TCCPermissionFixer.resetAndRequest(.accessibility)
            // 授权是异步的，短暂等待后刷新状态
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                isGranted = AXIsProcessTrusted()
                isRepairing = false
            }
        }
    }
}

// MARK: - Appearance tab

private struct AppearanceTab: View {
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @AppStorage("showGroupedSessions") private var showGrouped: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: L10n.screen) {
                ScreenPickerRow(screenSelector: screenSelector)
            }

            // Session-grouping toggle — sits alone now that the old
            // "Pixel Cat Mode" lives inside the Notch section's new
            // three-way Buddy Style picker.
            SettingsCard {
                TabToggle(icon: "folder", label: L10n.groupByProject, isOn: showGrouped) {
                    showGrouped.toggle()
                }
            }

            // Notch customization — theme, buddy style, font size,
            // visibility, hardware mode, and the live edit entry button.
            SettingsCard(title: L10n.notchSectionHeader) {
                NotchCustomizationSettingsView()
            }
        }
    }
}

// MARK: - Notifications tab

private struct NotificationsTab: View {
    @ObservedObject private var soundSelector = SoundSelector.shared
    @AppStorage("usageWarningThreshold") private var usageWarningThreshold: Int = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: L10n.notificationSound) {
                SoundPickerRow(soundSelector: soundSelector)
            }
            SettingsCard(title: L10n.usageWarningThreshold) {
                ThresholdPickerRow(threshold: $usageWarningThreshold)
            }
        }
    }
}

// MARK: - Behavior tab

private struct BehaviorTab: View {
    @AppStorage("smartSuppression") private var smartSuppression: Bool = true
    @AppStorage("autoCollapseOnMouseLeave") private var autoCollapseOnMouseLeave: Bool = true
    @AppStorage("compactCollapsed") private var compactCollapsed: Bool = false
    @AppStorage("quickReplyEnabled") private var quickReplyEnabled: Bool = true
    @AppStorage("codexNotifyOnComplete") private var codexNotifyOnComplete: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    TabToggle(icon: "eye.slash", label: L10n.smartSuppression, isOn: smartSuppression) { smartSuppression.toggle() }
                    TabToggle(icon: "rectangle.compress.vertical", label: L10n.autoCollapseOnMouseLeave, isOn: autoCollapseOnMouseLeave) { autoCollapseOnMouseLeave.toggle() }
                    TabToggle(icon: "rectangle.arrowtriangle.2.inward", label: L10n.compactCollapsed, isOn: compactCollapsed) { compactCollapsed.toggle() }
                    TabToggle(icon: "bell.badge", label: L10n.codexNotifyOnComplete, isOn: codexNotifyOnComplete) { codexNotifyOnComplete.toggle() }
                    TabToggle(icon: "sparkles", label: L10n.completionPanelEnabled,
                              isOn: quickReplyEnabled) { quickReplyEnabled.toggle() }
                }
            }
            SettingsCard(title: L10n.qrEditorSectionTitle) {
                QuickReplyPhrasesEditor()
                    .disabled(!quickReplyEnabled)
                    .opacity(quickReplyEnabled ? 1.0 : 0.5)
            }
        }
    }
}

// MARK: - CodeLight tab (Pair iPhone + Launch Presets merged)

private struct CodeLightTab: View {
    @ObservedObject private var syncManager = SyncManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: L10n.pairedIPhones) {
                HStack(spacing: 10) {
                    Image(systemName: syncManager.isEnabled
                          ? "iphone.radiowaves.left.and.right"
                          : "iphone.slash")
                        .font(.system(size: 14))
                        .foregroundColor(syncManager.isEnabled
                                         ? Theme.accent
                                         : Theme.subtle)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        if let url = syncManager.serverUrl,
                           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(URL(string: url)?.host ?? url)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.detailText.opacity(0.9))
                            Text(syncManager.isEnabled
                                 ? (L10n.isChinese ? "在线" : "Online")
                                 : (L10n.isChinese ? "未连接" : "Not connected"))
                                .font(.system(size: 10))
                                .foregroundColor(Theme.subtle)
                        } else {
                            Text(L10n.isChinese ? "尚未配置服务器" : "No server configured")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.subtleStrong)
                        }
                    }

                    Spacer()

                    Button {
                        QRPairingWindow.shared.show()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 11))
                            Text(L10n.pairNewPhone)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(Theme.backgroundInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Theme.accent)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            SettingsCard(title: L10n.launchPresetsSection) {
                PresetsListContent(textStyle: .darkOnLight(false))
                    .frame(minHeight: 280)
            }
        }
    }
}

// MARK: - Advanced tab

private struct AdvancedTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HookDiagnosticsView()

            SettingsCard(title: L10n.clearEndedSessions) {
                Button {
                    Task { await SessionStore.shared.process(.clearEndedSessions) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text(L10n.clearEnded)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(Theme.detailText.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.controlFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - About tab

private struct AboutTab: View {
    @ObservedObject private var updater = UpdaterManager.shared

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                HStack {
                    Text(L10n.version)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.detailText.opacity(0.9))
                    Spacer()
                    Text(version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.detailText.opacity(0.6))
                }
            }

            CheckForUpdatesCard(updater: updater)

            SettingsCard {
                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/xmqywx/CodeIsland")!)
                    } label: {
                        aboutLinkButton(icon: "star.fill", label: L10n.starOnGitHub)
                    }
                    .buttonStyle(.plain)

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/xmqywx/CodeIsland/issues")!)
                    } label: {
                        aboutLinkButton(icon: "bubble.left", label: L10n.feedback)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Plugin marketplace promo card
            SettingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.pluginMarketplaceTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.detailText.opacity(0.9))
                        Text(L10n.pluginMarketplaceDesc)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.detailText.opacity(0.55))
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://miomio.chat/plugins")!)
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.pluginMarketplaceOpen)
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(Theme.backgroundInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Theme.accent)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            SettingsCard {
                HStack {
                    Image(systemName: "message.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.detailText.opacity(0.6))
                    Text(L10n.wechatLabel)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.detailText.opacity(0.8))
                    Spacer()
                    Text("A115939")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.detailText.opacity(0.55))
                        .textSelection(.enabled)
                }
            }

            Text(L10n.maintainedTagline)
                .font(.system(size: 11))
                .foregroundColor(Theme.detailText.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                    Text(L10n.quitApp)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Theme.destructiveText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.destructiveFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.destructiveBorder, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private func aboutLinkButton(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
            Text(label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(Theme.backgroundInk)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.accent)
        )
    }
}

// MARK: - Check for Updates card (with hover)

private struct CheckForUpdatesCard: View {
    @ObservedObject var updater: UpdaterManager
    @State private var isHovered = false

    var body: some View {
        SettingsCard {
            // Auto-update opt-out (issue #87): Homebrew users let `brew` manage
            // updates and want the in-app background check off. Manual check
            // below still works either way.
            SettingRow(
                icon: "clock.arrow.2.circlepath",
                label: L10n.autoCheckForUpdates,
                sublabel: L10n.autoCheckForUpdatesHint,
                isLast: false
            ) {
                IOSToggle(isOn: updater.automaticallyChecksForUpdates) {
                    updater.setAutomaticUpdateChecks(!updater.automaticallyChecksForUpdates)
                }
            }

            Button {
                updater.checkForUpdates()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text(L10n.checkForUpdates)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.4)
                }
                .foregroundColor(isHovered ? Theme.accent : Theme.detailText.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheckForUpdates)
            .opacity(updater.canCheckForUpdates ? 1.0 : 0.5)
            .onHover { isHovered = $0 }
        }
    }
}

// MARK: - cmux Connection tab

/// Phone → terminal relay diagnostics. Replaces the invisible failure modes
/// that used to leave users with "phone says sent, cmux shows nothing".
private struct CmuxConnectionTab: View {
    @State private var probe: TerminalWriter.ConnectionProbe?
    @State private var isRefreshing = false
    @State private var testState: TestState = .idle
    @State private var testDetail: String = ""
    @State private var automationState: AutomationState = .idle
    @State private var automationDetail: String = ""

    enum TestState { case idle, sending, done }
    enum AutomationState { case idle, requesting, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.cmuxTabHeader)
                .font(.system(size: 11))
                .foregroundColor(Theme.subtle)

            SettingsCard {
                statusRow(
                    icon: "terminal.fill",
                    title: L10n.cmuxBinaryRow,
                    ok: probe?.cmuxBinaryInstalled ?? false,
                    detail: (probe?.cmuxBinaryInstalled ?? false)
                        ? (probe?.cmuxBinaryPath ?? L10n.cmuxBinaryFound)
                        : L10n.cmuxBinaryMissing
                )
                statusRow(
                    icon: "accessibility",
                    title: L10n.accessibilityRowTitle,
                    ok: probe?.accessibilityGranted ?? false,
                    detail: (probe?.accessibilityGranted ?? false) ? L10n.accessibilityGranted : L10n.accessibilityDenied
                )
                statusRow(
                    icon: "gearshape.2",
                    title: L10n.automationRowTitle,
                    ok: probe?.automationGranted,
                    detail: probe?.automationDetail ?? L10n.automationUnknown
                )
                statusRow(
                    icon: "person.crop.rectangle.stack",
                    title: L10n.runningClaudeCount,
                    ok: (probe?.claudeSessionCount ?? 0) > 0,
                    detail: "\(probe?.claudeSessionCount ?? 0)"
                )
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await runTest() }
                        } label: {
                            HStack(spacing: 6) {
                                if testState == .sending {
                                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                                } else {
                                    Image(systemName: "paperplane.fill").font(.system(size: 11))
                                }
                                Text(testState == .sending ? L10n.testSending : L10n.testSendButton)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(Theme.backgroundInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(testState == .sending)

                        Button {
                            Task { await refresh() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 11))
                                Text(L10n.refreshStatus).font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(Theme.detailText.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.controlFill))
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefreshing)
                    }

                    if testState == .done, !testDetail.isEmpty {
                        Text(testDetail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.subtleStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard {
                VStack(spacing: 8) {
                    // 一键修复：升级后 ad-hoc 签名 CDHash 变化导致 TCC 失效时用
                    repairButton(label: L10n.repairAccessibilityPermission, service: .accessibility)
                    repairButton(label: L10n.repairAutomationPermission, service: .appleEvents)

                    Divider().background(Color.white.opacity(0.06)).padding(.vertical, 2)

                    // 备用通道：打开系统设置手动处理
                    permissionButton(label: L10n.openAccessibilitySettings, urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    permissionButton(label: L10n.openAutomationSettings, urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")

                    // Proactive Automation-prompt trigger. macOS won't let the
                    // user add an app to the Automation whitelist manually;
                    // tapping this dispatches a no-op `activate` AppleEvent
                    // to the first running terminal, surfacing the TCC dialog.
                    Button {
                        Task { await requestAutomation() }
                    } label: {
                        HStack(spacing: 8) {
                            if automationState == .requesting {
                                ProgressView().scaleEffect(0.5).frame(width: 11, height: 11)
                            } else {
                                Image(systemName: "hand.raised.fill").font(.system(size: 11))
                            }
                            Text(L10n.requestAutomationButton).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 9)).opacity(0.4)
                        }
                        .foregroundColor(Theme.detailText.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(automationState == .requesting)

                    if automationState == .done, !automationDetail.isEmpty {
                        Text(automationDetail)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.subtleStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private func repairButton(label: String, service: TCCService) -> some View {
        Button {
            Task {
                await TCCPermissionFixer.resetAndRequest(service)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await refresh()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).opacity(0.5)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
        }
        .buttonStyle(.plain)
    }

    private func requestAutomation() async {
        automationState = .requesting
        automationDetail = ""
        let (_, detail) = await TerminalWriter.shared.requestAutomationPermission()
        automationDetail = detail
        automationState = .done
    }

    @ViewBuilder
    private func statusRow(icon: String, title: String, ok: Bool?, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Theme.subtleStrong)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.detailText.opacity(0.9))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.subtle)
            }
            Spacer()
            Circle()
                .fill(dotColor(ok))
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 4)
    }

    private func dotColor(_ ok: Bool?) -> Color {
        switch ok {
        case .some(true): return Theme.success
        case .some(false): return Theme.error
        case .none: return Theme.neutralDot
        }
    }

    private func permissionButton(label: String, urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).opacity(0.4)
            }
            .foregroundColor(Theme.detailText.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func refresh() async {
        isRefreshing = true
        let p = await TerminalWriter.shared.probeConnection()
        self.probe = p
        isRefreshing = false
    }

    private func runTest() async {
        testState = .sending
        testDetail = ""
        let (ok, detail) = await TerminalWriter.shared.testSendDiagnostic()
        testDetail = detail
        testState = .done
        // Also refresh the status rows while we're at it.
        let p = await TerminalWriter.shared.probeConnection()
        self.probe = p
        _ = ok
    }
}

// MARK: - Logs tab

/// Live tail of ~/.claude/.codeisland.log with issue-submission affordances.
/// Exists to turn "CodeIsland is broken, help" into something users can
/// self-serve into a GitHub issue without scrolling for log files.
private struct LogsTab: View {
    @StateObject private var streamer = LogStreamer.shared
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.logsHeader)
                .font(.system(size: 11))
                .foregroundColor(Theme.subtle)

            HStack(spacing: 8) {
                toolbarButton(icon: "doc.on.doc", label: justCopied ? L10n.logsCopied : L10n.logsCopyAll) {
                    let snapshot = streamer.currentSnapshot()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snapshot, forType: .string)
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        justCopied = false
                    }
                }
                toolbarButton(icon: "folder", label: L10n.logsOpenFile) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: streamer.logFilePath)])
                }
                toolbarButton(icon: "exclamationmark.bubble", label: L10n.logsSubmitIssue) {
                    openIssue()
                }
            }

            SettingsCard {
                logView
            }
        }
        .task {
            streamer.startIfNeeded()
        }
        .onDisappear {
            streamer.stopIfUnused()
        }
    }

    @ViewBuilder
    private var logView: some View {
        if streamer.lines.isEmpty {
            Text(L10n.logsEmpty)
                .font(.system(size: 11))
                .foregroundColor(Theme.subtle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(streamer.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(colorFor(line: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 320)
                .onChange(of: streamer.lines.count) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func colorFor(line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") {
            return Theme.error
        }
        if lower.contains("warning") || lower.contains("timeout") {
            return Theme.warning
        }
        return Theme.detailText.opacity(0.8)
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Theme.detailText.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.controlFill))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.controlBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func openIssue() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = Foundation.ProcessInfo.processInfo.operatingSystemVersionString

        // 1. Put the FULL log on the clipboard. GitHub's issue-new endpoint
        //    caps prefilled URLs around 8KB — 200 lines URL-encoded blows
        //    past that and the page breaks. Clipboard has no such limit,
        //    so users can paste arbitrarily large logs into the textarea.
        let fullSnapshot = streamer.currentSnapshot()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullSnapshot, forType: .string)

        // 2. Put a short tail inline in the URL as a preview. A normal line is
        //    ~100 chars, so 20 lines × 3x URL-encoding ≈ 6KB — fits under the
        //    8KB limit. But a single stack trace line can be 500+ chars and
        //    blow the budget with even 10 lines. So we measure the actual
        //    encoded URL length and progressively shrink the tail until it
        //    fits under `maxURLBytes`, falling back to an empty preview if
        //    even 1 line is too fat. The clipboard copy above guarantees the
        //    user can always paste the full log regardless.
        let maxURLBytes = 6000  // conservative — GitHub's hard limit is ~8KB
        var previewLineCount = 20
        var finalURL: URL?
        while previewLineCount >= 0 {
            let tail = previewLineCount > 0
                ? streamer.lines.suffix(previewLineCount).joined(separator: "\n")
                : "(omitted — see clipboard)"

            let body = """
            **Describe the issue**
            <!-- What happened? What did you expect? -->

            **Environment**
            - CodeIsland: \(version) (build \(build))
            - macOS: \(os)

            **Recent logs (preview — last \(previewLineCount) lines)**
            ```
            \(tail)
            ```

            **Full log**
            > \(L10n.logsIssueClipboardNotice)

            ```
            <!-- paste here -->
            ```
            """

            var comps = URLComponents(string: "https://github.com/MioMioOS/MioIsland/issues/new")!
            comps.queryItems = [
                URLQueryItem(name: "title", value: "[Bug] "),
                URLQueryItem(name: "body", value: body)
            ]
            if let candidate = comps.url, candidate.absoluteString.count <= maxURLBytes {
                finalURL = candidate
                break
            }
            // Halve and retry (20 → 10 → 5 → 2 → 1 → 0).
            if previewLineCount == 0 { break }
            previewLineCount = previewLineCount > 1 ? previewLineCount / 2 : 0
        }

        if let url = finalURL {
            NSWorkspace.shared.open(url)
        }
    }
}
