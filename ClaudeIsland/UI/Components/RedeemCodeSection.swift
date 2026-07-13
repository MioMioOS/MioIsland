//
//  RedeemCodeSection.swift
//  ClaudeIsland
//
//  Shared "已有兑换码？" section for the Pair Phone surfaces. Two
//  visual surfaces use this:
//    1. PairPhonePanelView — dark theme via ThemeResolver
//    2. QRPairingContentView — lime card background, near-black text
//  Same logic, different chrome → one Style enum drives the colors.
//
//  Behaviour:
//   - Disclosure ("已有兑换码？") — collapsed by default so newcomers
//     aren't visually nagged. Power users with codes click to expand.
//   - Input is uppercased + trimmed on submit. No regex on Mac side;
//     the server is the source of truth.
//   - Submit button only enabled when SyncManager is connected
//     (otherwise we have no Bearer token and would 401).
//   - Success → SyncManager.lastRedemption updates → banner shows
//     above this section. Input clears. Section stays expanded so
//     user sees the result, but they can also collapse.
//   - Error → red message under input. Pressing Activate again is
//     allowed immediately — no rate-limit cooldown on client; server
//     enforces.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class RedeemCodeFlow: ObservableObject {
    @Published var input: String = ""
    @Published var isExpanded: Bool = false
    @Published var isSubmitting: Bool = false
    @Published var lastError: RedeemError? = nil

    /// Trim + uppercase preview — what we'd send if Activate were tapped now.
    /// Used by the placeholder vs filled state and the submit gate.
    var normalizedCode: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var canSubmit: Bool {
        !normalizedCode.isEmpty && !isSubmitting
    }

    func submit() async {
        // Re-entry guard: TextField's `.onSubmit { Task { await flow.submit() } }`
        // bypasses the button's `.disabled(!submitEnabled)` because Enter goes
        // through the keyboard, not the button. Without this guard, holding
        // Enter or hitting it twice quickly would fire two redeem requests.
        // Server has `already_redeemed` + rate_limit defenses, but client
        // shouldn't burn the user's rate budget over a double-tap.
        guard !isSubmitting else { return }
        let code = normalizedCode
        guard !code.isEmpty else { return }
        isSubmitting = true
        lastError = nil
        do {
            let record = try await SyncManager.shared.redeemCode(code)
            input = ""
            // Full-screen celebration: NSPanel-based overlay floats above the
            // whole Mac display so the moment doesn't feel cramped to the
            // 280pt pairing popup. Auto-dismisses ~3.2s later via its own
            // internal task, so we don't have to hold state here.
            CelebrationOverlay.shared.present(days: record.durationDays)
        } catch let e as RedeemError {
            lastError = e
        } catch {
            // Defensive: SyncManager.redeemCode only throws RedeemError
            // today, but Swift's untyped throws keeps this branch needed
            // for exhaustiveness. Log it explicitly so an unexpected
            // error type doesn't quietly map to "network error" — that
            // would hide a real bug.
            NSLog("[redeem] unexpected error type: \(error)")
            lastError = .malformedResponse
        }
        isSubmitting = false
    }
}

struct RedeemCodeSection: View {
    @ObservedObject var syncManager: SyncManager
    @StateObject private var flow = RedeemCodeFlow()
    @State private var isRefreshing: Bool = false
    let style: Style

    /// Connection state from SyncManager — gate the Activate button so
    /// users without a token can't fire a 401.
    private var isConnected: Bool {
        syncManager.connectionState == .connected
    }

    var body: some View {
        VStack(spacing: 8) {
            // Status banner is ALWAYS visible — user must always know
            // whether they're in trial, expired, paid, or unactivated.
            // Earlier "hide when not active" design caused confusion:
            // expired users saw a blank panel and couldn't tell if their
            // trial ended or the app was just broken.
            statusBanner(currentStatus())
            disclosureHeader
            if flow.isExpanded {
                inputBlock
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Force-refresh subscription state every time the Pair Phone
            // surface appears. Without this, the banner is stale until
            // the next reconnect or socket push — bad UX if the trial
            // expired while the panel was closed (admin SQL grant, IAP
            // refund, etc. that didn't emit a socket event).
            Task { await syncManager.refreshSubscription() }
        }
    }

    // MARK: - Banner state resolution
    //
    // Resolves the user's current subscription state into one of four
    // visual states. Reads server truth first, falls back to local
    // redemption record only when server has no record (covers the
    // post-redeem instant before server's push lands).

    private enum BannerKind {
        case trial(daysLeft: Int)
        /// lifetime / paid subscription. `lifetime` = no expiry at all
        /// (permanent IAP); `inherited` = the linked iPhone owns the
        /// purchase (server reason `inherited_from_phone_paid`).
        case active(lifetime: Bool, inherited: Bool)
        case expired
        case none

        var iconName: String {
            switch self {
            case .trial, .active: return "crown.fill"
            case .expired:        return "hourglass"
            case .none:           return "ticket"
            }
        }

        var label: String {
            switch self {
            case .trial(let d): return L10n.subscriptionTrialBanner(daysLeft: d)
            case .active(let lifetime, let inherited):
                if inherited { return L10n.subscriptionActiveInheritedBanner }
                return lifetime ? L10n.subscriptionActiveLifetimeBanner
                                : L10n.subscriptionActiveBanner
            case .expired:      return L10n.subscriptionExpiredBanner
            case .none:         return L10n.subscriptionNoneBanner
            }
        }
    }

    private func currentStatus() -> BannerKind {
        // Server truth wins when present
        if let sub = syncManager.subscription {
            switch sub.status {
            case .trial:
                if sub.isActive {
                    return .trial(daysLeft: sub.daysLeftDisplay)
                }
                return .expired
            case .active:
                // Lifetime = active with no expiry (server omits expiresAt
                // and daysLeft for permanent unlocks — ISS-06 server fix).
                return .active(
                    lifetime: sub.expiresAt == nil && sub.daysLeft == nil,
                    inherited: sub.source == "inherited"
                )
            case .expired:
                return .expired
            case .none:
                // Server says no — but check the local cache for a
                // just-now redemption that the server hasn't echoed yet.
                if let red = syncManager.lastRedemption, red.isActive {
                    return .trial(daysLeft: red.daysLeft)
                }
                return .none
            }
        }
        // No subscription state at all (first launch, decode failed)
        if let red = syncManager.lastRedemption, red.isActive {
            return .trial(daysLeft: red.daysLeft)
        }
        return .none
    }

    // MARK: - Banner view (always visible)

    private func statusBanner(_ kind: BannerKind) -> some View {
        let accent = bannerAccent(for: kind)
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: kind.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
            Text(kind.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(style.successText)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 4)
            refreshButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(bannerBackground(for: kind))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(accent.opacity(0.30), lineWidth: 0.5)
                )
        )
    }

    private func bannerAccent(for kind: BannerKind) -> Color {
        switch kind {
        case .trial, .active: return style.successAccent
        case .expired:        return style.errorAccent
        case .none:           return style.subduedText
        }
    }

    private func bannerBackground(for kind: BannerKind) -> Color {
        switch kind {
        case .trial, .active: return style.successBackground
        case .expired, .none: return style.inputBackground
        }
    }

    /// Manual refresh trigger — replaces the static icon with a spinner
    /// while in flight. Tapping fires a force-refetch against the server.
    /// Useful when admin-side state changes (SQL grant, IAP refund) don't
    /// emit a socket event the Mac would otherwise listen for.
    private var refreshButton: some View {
        Button {
            guard !isRefreshing else { return }
            Task {
                isRefreshing = true
                await syncManager.refreshSubscription()
                // Brief minimum spin so the user perceives the action
                // happened even if the network round-trip is < 100ms.
                try? await Task.sleep(nanoseconds: 350_000_000)
                isRefreshing = false
            }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundColor(style.subduedText)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.subscriptionRefreshTooltip)
        .disabled(isRefreshing)
    }

    // MARK: - Disclosure header (collapsed default)

    private var disclosureHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                flow.isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ticket")
                    .font(.system(size: 11))
                    .foregroundColor(style.subduedText)
                Text(L10n.redeemSectionTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(style.subduedText)
                Spacer()
                Image(systemName: flow.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(style.subduedText.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Input + activate

    private var inputBlock: some View {
        VStack(spacing: 8) {
            Text(L10n.redeemSectionSubtitle)
                .font(.system(size: 10.5))
                .foregroundColor(style.subduedText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(L10n.redeemPlaceholder, text: $flow.input)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(style.primaryText)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(style.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style.inputBorder, lineWidth: 0.5)
                )
                .onChange(of: flow.input) { _, newValue in
                    let upper = newValue.uppercased()
                    if upper != newValue { flow.input = upper }
                    if flow.lastError != nil { flow.lastError = nil }
                }
                .onSubmit {
                    Task { await flow.submit() }
                }
                .disabled(flow.isSubmitting)

            if let err = flow.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(err.displayMessage)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(style.errorAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, -2)
            } else if !isConnected {
                Text(L10n.redeemDisabledOffline)
                    .font(.system(size: 10.5))
                    .foregroundColor(style.subduedText.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, -2)
            }

            Button {
                Task { await flow.submit() }
            } label: {
                HStack(spacing: 6) {
                    if flow.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .tint(style.submitForegroundEnabled)
                    }
                    Text(flow.isSubmitting ? L10n.redeemButtonSubmitting : L10n.redeemButton)
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundColor(submitEnabled ? style.submitForegroundEnabled : style.submitForegroundDisabled)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(submitEnabled ? style.submitBackgroundEnabled : style.submitBackgroundDisabled)
                )
            }
            .buttonStyle(.plain)
            .disabled(!submitEnabled)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var submitEnabled: Bool {
        flow.canSubmit && isConnected
    }

    // MARK: - Style

    /// Color tokens for the two surfaces. `panel` for the dark plugin
    /// panel (uses ThemeResolver), `limeCard` for the popup window's
    /// lime brand card.
    struct Style {
        let primaryText: Color
        let subduedText: Color
        let inputBackground: Color
        let inputBorder: Color
        let errorAccent: Color
        let successAccent: Color
        let successText: Color
        let successBackground: Color
        let submitForegroundEnabled: Color
        let submitForegroundDisabled: Color
        let submitBackgroundEnabled: Color
        let submitBackgroundDisabled: Color

        /// Dark-on-lime card style (QRPairingContentView popup). The card
        /// is already lime so the submit button uses near-black text on
        /// dark inverse background to stand out against the surrounding
        /// lime field.
        static let limeCard: Style = .init(
            primaryText: .black.opacity(0.95),
            subduedText: .black.opacity(0.6),
            inputBackground: .black.opacity(0.08),
            inputBorder: .black.opacity(0.12),
            errorAccent: Color(red: 0xC4/255, green: 0x12/255, blue: 0x12/255),
            successAccent: Color(red: 0x0E/255, green: 0x6F/255, blue: 0x2E/255),
            successText: .black.opacity(0.85),
            successBackground: .black.opacity(0.06),
            submitForegroundEnabled: Color(red: 0xCA/255, green: 0xFF/255, blue: 0x00/255),
            submitForegroundDisabled: .black.opacity(0.35),
            submitBackgroundEnabled: .black.opacity(0.85),
            submitBackgroundDisabled: .black.opacity(0.12)
        )

        /// Dark-panel style — caller passes a ThemeResolver and we
        /// derive the tokens from it. Keeps Mio Island's theme system
        /// authoritative for the plugin panel surface.
        static func darkPanel(theme: ThemeResolver) -> Style {
            Style(
                primaryText: theme.primaryText,
                subduedText: theme.secondaryText,
                inputBackground: theme.overlay.opacity(0.16),
                inputBorder: theme.border.opacity(0.7),
                errorAccent: theme.errorColor,
                successAccent: theme.doneColor,
                successText: theme.primaryText,
                successBackground: theme.doneColor.opacity(0.12),
                submitForegroundEnabled: theme.inverseText,
                submitForegroundDisabled: theme.mutedText,
                submitBackgroundEnabled: theme.primaryText.opacity(0.92),
                submitBackgroundDisabled: theme.overlay.opacity(0.18)
            )
        }
    }
}

// MARK: - Full-screen celebration overlay
//
// On a successful redemption we float a borderless NSPanel above every
// window of every space — confetti rains from the top, a hero card pops
// in the dead center of the main display. The panel ignores mouse events
// so it never blocks the user from continuing to interact with the
// pairing popup (or anything else) underneath.
//
// Why NSPanel and not a SwiftUI `.fullScreenCover` modifier:
//   - MioIsland is LSUIElement=true (no dock icon, menubar-only). A
//     SwiftUI modifier would attach to a hosting NSWindow which we'd then
//     have to size and place ourselves anyway. NSPanel + NSHostingView
//     lets us go borderless + click-through in a few lines, and the panel
//     can sit above arbitrary other app windows on the screen.
//   - .canJoinAllSpaces lets the confetti follow the user if they redeem
//     from a Space the main window isn't currently on.
//   - .nonactivatingPanel ensures we don't steal focus from whatever the
//     user is doing (text field, terminal, etc).

@MainActor
final class CelebrationOverlay {
    static let shared = CelebrationOverlay()
    private init() {}

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// Total time the overlay stays on screen, including fade-out. Tuned
    /// long enough to read the hero text without feeling like it lingers.
    private let onScreenSeconds: Double = 3.2

    func present(days: Int) {
        // Cancel any in-flight celebration so a rapid second redeem replaces
        // the previous one cleanly rather than overlapping or being canceled
        // mid-flight by a late dismiss timer.
        dismissTask?.cancel()
        if let existing = panel {
            existing.orderOut(nil)
            panel = nil
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Sit one tick above the *highest* window level the OS exposes —
        // `kCGMaximumWindowLevel` (which QRPairingWindow and PresetSettings
        // use). `.screenSaver` (1000) was not enough: those windows are at
        // ~2_147_483_631 and would visually cover the celebration. +1 makes
        // sure the confetti never gets buried, regardless of what other
        // app windows the user has up.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: FullScreenCelebration(days: days))
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()

        panel = p

        dismissTask = Task { @MainActor [weak self] in
            guard let seconds = self?.onScreenSeconds else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let p = panel else { return }
        // Fade the panel out via animator before tearing down, so it doesn't
        // pop offscreen. NSPanel animator honors animationContext duration.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            p.orderOut(nil)
            self?.panel = nil
        })
    }
}

/// Hero center card + falling confetti, sized to fill an NSPanel set to
/// the entire screen frame.
private struct FullScreenCelebration: View {
    let days: Int
    private static let limeBrand = Color(red: 0xCA/255, green: 0xFF/255, blue: 0x00/255)

    var body: some View {
        ZStack {
            // No background fill — keeps the desktop visible behind the
            // celebration so it feels like an overlay, not a takeover.
            FullScreenConfettiShower()

            VStack(spacing: 18) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Self.limeBrand, Self.limeBrand.opacity(0.75)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Self.limeBrand.opacity(0.6), radius: 30)
                    .symbolEffect(.bounce.up.byLayer, value: days)

                Text(L10n.redeemSuccessTitle)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)

                Text(L10n.redeemSuccessDays(days))
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 2)
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 44)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(Self.limeBrand.opacity(0.7), lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 40, x: 0, y: 16)
            )
            .scaleEffect(1.0)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}

/// Full-display confetti shower. 80 pieces feel substantial without being
/// noisy; geometry reader picks up the panel's actual size so each piece
/// can fall the full screen height regardless of monitor resolution.
private struct FullScreenConfettiShower: View {
    private static let palette: [Color] = [
        Color(red: 0xCA/255, green: 0xFF/255, blue: 0x00/255), // brand lime
        Color(red: 0xCA/255, green: 0xFF/255, blue: 0x00/255), // brand lime ×2 weight
        Color(red: 1.00,    green: 0.85,    blue: 0.20),       // sunshine
        Color(red: 1.00,    green: 0.45,    blue: 0.65),       // pink
        Color(red: 0.40,    green: 0.75,    blue: 1.00),       // sky
        Color(red: 1.00,    green: 0.55,    blue: 0.15),       // orange
        Color(red: 0.55,    green: 0.85,    blue: 0.45),       // mint
        Color(red: 0.65,    green: 0.45,    blue: 1.00),       // violet
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<80, id: \.self) { i in
                    FullScreenConfettiPiece(
                        color: Self.palette[i % Self.palette.count],
                        screenWidth: geo.size.width,
                        screenHeight: geo.size.height,
                        delay: Double(i) * 0.02
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct FullScreenConfettiPiece: View {
    let color: Color
    let screenWidth: CGFloat
    let screenHeight: CGFloat
    let delay: Double

    @State private var animate = false
    // Per-piece random params chosen once at init so SwiftUI's body
    // recomposition can't re-roll them (which would cause the piece to
    // teleport mid-fall).
    private let startX: CGFloat
    private let endXDrift: CGFloat
    private let width: CGFloat
    private let height: CGFloat
    private let rotations: Double
    private let duration: Double

    init(color: Color, screenWidth: CGFloat, screenHeight: CGFloat, delay: Double) {
        self.color = color
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.delay = delay
        self.startX = .random(in: 0...screenWidth)
        self.endXDrift = .random(in: -120...120)
        self.width = .random(in: 8...14)
        self.height = .random(in: 14...22)
        self.rotations = .random(in: 2.0...5.0)
        self.duration = .random(in: 2.6...3.4)
    }

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: height)
            .position(
                x: animate ? startX + endXDrift : startX,
                y: animate ? screenHeight + 60 : -80
            )
            .rotationEffect(.degrees(animate ? 360.0 * rotations : 0))
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: duration).delay(delay)) {
                    animate = true
                }
            }
    }
}
