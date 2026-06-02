//
//  PairPhoneView.swift
//  ClaudeIsland
//
//  QR code pairing button in settings menu + floating QR window.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

private func pairPhoneTheme() -> ThemeResolver {
    ThemeResolver(theme: NotchCustomizationStore.shared.customization.theme)
}

// MARK: - QR payload (#118 — one QR = monitoring + workspace by default)

/// Builds the JSON payload the CodeLight camera parses. A single scan carries
/// BOTH the monitoring shortCode AND a workspace enrollment intent so the phone
/// pairs monitoring AND configures the workspace daemon in one scan.
///
/// #118 default behavior: when this Mac is enrollable and not already enrolled,
/// the QR surface proactively creates the enrollment intent on appear
/// (MioAgentEnroller.ensureWorkspaceIntentForQR), so the EMITTED QR is `kind:"both"`
/// by default — the user is NOT asked to scan twice. The single payload encodes
/// everything CodeLight needs: one scan → device joins monitoring AND its workspace.
///
/// Shape (coordinated with the CodeLight camera parser):
///   {
///     "server": "<url>",
///     "code": "<monitoring shortCode>",
///     "enroll_intent_id": "<uuid>",   // present when workspace pairing is offered
///     "enroll_code": "<opaque>",      // present when workspace pairing is offered
///     "kind": "monitor" | "workspace" | "both"
///   }
/// - kind "both"      → DEFAULT: monitoring + workspace (one scan does everything).
/// - kind "monitor"   → degraded: only monitoring (already enrolled, or daemon not
///                       launchable — workspace setup never blocks the monitor pair).
/// - kind "workspace" → only an enrollment intent (no monitoring code yet).
enum PairQRPayload {
    static func make(serverUrl: String, shortCode: String?, enrollIntent: MioEnrollIntent?) -> Data? {
        let hasMonitor = !(shortCode ?? "").isEmpty

        // Workspace enrollment present → emit the SAME canonical `mio://enroll/<id>?code=…&server=…
        // &name=…&platform=…&arch=…` deeplink that `mio-agent login` produces and CodeLight already
        // parses. Single source of truth — no bespoke JSON. The monitoring shortCode rides along as
        // an optional `monitor_code` query param so ONE scan does workspace + monitoring (#118).
        if let enroll = enrollIntent {
            var deeplink = enroll.deeplink
            if hasMonitor {
                let encoded = shortCode!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? shortCode!
                deeplink += (deeplink.contains("?") ? "&" : "?") + "monitor_code=\(encoded)"
            }
            return deeplink.data(using: .utf8)
        }

        // Monitoring-only fallback (no workspace daemon enrolled): legacy { server, code } JSON,
        // which CodeLight's monitoring branch still understands.
        if hasMonitor {
            return try? JSONSerialization.data(withJSONObject: ["server": serverUrl, "code": shortCode!])
        }

        return nil
    }

    /// Render `payload` JSON into a crisp, scannable QR NSImage.
    static func qrImage(from payload: Data) -> NSImage? {
        guard let jsonString = String(data: payload, encoding: .utf8) else { return nil }
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(jsonString.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// MARK: - Menu Row (inside NotchMenuView)

struct PairPhoneRow: View {
    @ObservedObject var syncManager = SyncManager.shared
    @State private var isHovered = false
    private var theme: ThemeResolver { pairPhoneTheme() }

    var body: some View {
        Button {
            QRPairingWindow.shared.show()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                    .frame(width: 16)

                Text("Pair iPhone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)

                Spacer()

                if syncManager.isEnabled {
                    HStack(spacing: 3) {
                        Circle().fill(theme.doneColor).frame(width: 5, height: 5)
                        Text("Online")
                            .font(.system(size: 9))
                            .foregroundColor(theme.doneColor)
                    }
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 11))
                        .foregroundColor(theme.mutedText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? theme.overlay.opacity(0.22) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Key-capable borderless window

/// A borderless NSWindow that can still become key, allowing
/// TextField / text input to receive keyboard focus.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - Floating QR Window

@MainActor
final class QRPairingWindow {
    static let shared = QRPairingWindow()

    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = QRPairingContentView {
            self.close()
        }

        let hostingView = NSHostingView(rootView: contentView)
        let windowWidth: CGFloat = 280
        let windowHeight: CGFloat = 560
        let w = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.contentView = hostingView

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x = screenFrame.midX - windowWidth / 2
            let y = screenFrame.midY - windowHeight / 2
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        w.makeKeyAndOrderFront(nil)
        w.isReleasedWhenClosed = false

        // Close on click outside
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak w] event in
            if let window = w, !NSPointInRect(event.locationInWindow, window.contentView?.bounds ?? .zero) {
                if event.window != window {
                    self.close()
                }
            }
            return event
        }

        self.window = w
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - QR Content View

private struct QRPairingContentView: View {
    let onClose: () -> Void
    @ObservedObject private var syncManager = SyncManager.shared
    /// Observe the enroller so the QR re-renders into a dual (kind:"both") QR
    /// the moment an in-app `mio-agent login` parses its enrollment intent.
    @ObservedObject private var enroller = MioAgentEnroller.shared
    @State private var qrImage: NSImage?
    @State private var deviceName = Host.current().localizedName ?? "Mac"
    @State private var isHoveringClose = false
    @State private var serverDraft = ""
    @State private var isSavingServer = false
    /// When true, force the "enter server URL" form even though a URL is
    /// already configured — user tapped the edit action to change it.
    @State private var isEditingServer = false
    @State private var linkedDevices: [ServerConnection.LinkedDeviceInfo] = []
    @State private var isUnlinking: String? = nil

    /// Solid brand fill for the popup card — bold, opaque, always readable.
    /// Replaces the old ultraThinMaterial which was so transparent the
    /// window was literally hard to locate against a similar background.
    private static let cardFill = Color(red: 0xCA/255, green: 0xFF/255, blue: 0x00/255)
    /// Near-black text that reads comfortably on the lime card.
    private static let cardText = Color.black

    private var serverUrl: String? {
        let value = SyncManager.shared.serverUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    private var shortCode: String? {
        syncManager.shortCode
    }

    var body: some View {
        VStack(spacing: 14) {
            // Close button
            HStack {
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Self.cardText.opacity(isHoveringClose ? 0.8 : 0.5))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringClose = $0 }
            }
            .padding(.bottom, -8)

            if let url = serverUrl, !isEditingServer {
                pairingContent(serverUrl: url)
            } else {
                notConfiguredContent
            }
        }
        .padding(20)
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Self.cardFill)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Self.cardText.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .onAppear {
            // #118: one QR = monitoring + workspace by default. Proactively create
            // a workspace enrollment intent (no-op if already enrolled / daemon
            // unavailable) so the single QR carries both capabilities.
            enroller.ensureWorkspaceIntentForQR(serverUrl: serverUrl)
            generateQRCode()
            Task { await refreshLinkedDevices() }
        }
        .onChange(of: shortCode) { _, _ in
            generateQRCode()
        }
        .onChange(of: enroller.intent) { _, _ in
            generateQRCode()
        }
    }

    // MARK: - Content subviews

    /// Normal paired state: QR, short code, info pills.
    @ViewBuilder
    private func pairingContent(serverUrl: String) -> some View {
        // QR Code — keep a white card background so the generated black
        // pixels stay crisp and scannable against the lime background.
        if let qrImage {
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white)
                )
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(Self.cardText.opacity(0.08))
                .frame(width: 184, height: 184)
                .overlay(ProgressView().tint(Self.cardText.opacity(0.45)))
        }

        // Caption — reflect "one scan = monitoring + workspace" (#118) when the
        // QR carries a workspace enrollment intent (the default for an enrollable Mac).
        Text(enroller.intent != nil ? L10n.pairScanCaptionBoth : "Scan or enter code")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Self.cardText.opacity(0.6))

        // Big short code display
        Text(shortCode ?? "------")
            .font(.system(size: 28, weight: .bold, design: .monospaced))
            .tracking(4)
            .foregroundColor(Self.cardText.opacity(shortCode == nil ? 0.3 : 0.95))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Self.cardText.opacity(0.08))
            )

        // Info pills — the server pill is clickable to edit.
        HStack(spacing: 8) {
            Button {
                serverDraft = serverUrl
                withAnimation(.easeInOut(duration: 0.18)) {
                    isEditingServer = true
                }
            } label: {
                infoPillContent(
                    icon: "link",
                    text: URL(string: serverUrl)?.host ?? serverUrl,
                    trailing: "pencil"
                )
            }
            .buttonStyle(.plain)
            .help("Change server URL")

            infoPillContent(icon: "desktopcomputer", text: deviceName)
        }

        // Linked devices section
        if !linkedDevices.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    Text("Linked Devices")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Self.cardText.opacity(0.6))
                    Spacer()
                    Text("\(linkedDevices.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Self.cardText.opacity(0.5))
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)

                ForEach(linkedDevices) { device in
                    HStack(spacing: 6) {
                        Image(systemName: device.kind == "iphone" ? "iphone" : "desktopcomputer")
                            .font(.system(size: 10))
                            .foregroundColor(Self.cardText.opacity(0.7))
                        Text(device.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Self.cardText.opacity(0.9))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            Task { await unlinkDevice(device) }
                        } label: {
                            if isUnlinking == device.id {
                                ProgressView().controlSize(.small).scaleEffect(0.6)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(Self.cardText.opacity(0.4))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isUnlinking != nil)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Self.cardText.opacity(0.06))
                    )
                }
            }
            .padding(.top, 4)
        }
    }

    /// Empty state (or edit mode) — lets the user type a server URL inline
    /// and save it. No separate Settings window needed.
    @ViewBuilder
    private var notConfiguredContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Self.cardText.opacity(0.55))

            VStack(spacing: 4) {
                Text(isEditingServer ? "Change Server" : "CodeLight Server")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Self.cardText.opacity(0.95))
                Text(isEditingServer
                     ? "Enter a new server URL. The current Mac will reconnect after saving."
                     : "Enter your self-hosted server URL to start pairing.")
                    .font(.system(size: 11))
                    .foregroundColor(Self.cardText.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)

            TextField("https://your-server.example", text: $serverDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Self.cardText.opacity(0.95))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Self.cardText.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Self.cardText.opacity(0.25), lineWidth: 0.5)
                )
                .padding(.horizontal, 4)
                .disabled(isSavingServer)

            HStack(spacing: 8) {
                if isEditingServer {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isEditingServer = false
                            serverDraft = ""
                        }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Self.cardText.opacity(0.08))
                            )
                            .foregroundColor(Self.cardText.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Self.cardText.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    saveServerURL()
                } label: {
                    HStack(spacing: 6) {
                        if isSavingServer {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        }
                        Text(isSavingServer ? "Connecting…" : (isEditingServer ? "Save" : "Save and Connect"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isValidDraft ? Self.cardText.opacity(0.9) : Self.cardText.opacity(0.15))
                    )
                    .foregroundColor(isValidDraft ? Self.cardFill : Self.cardText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!isValidDraft || isSavingServer)
            }
            .padding(.horizontal, 4)

            Text("This URL is stored locally. It never leaves your Mac.")
                .font(.system(size: 10))
                .foregroundColor(Self.cardText.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    private var isValidDraft: Bool {
        let s = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && (u.host?.isEmpty == false)
    }

    private func saveServerURL() {
        let s = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDraft else { return }
        isSavingServer = true
        SyncManager.shared.serverUrl = s
        // SyncManager.serverUrl didSet triggers connectToServer automatically,
        // which populates shortCode + flips isEnabled. The view will re-render
        // into pairingContent as soon as syncManager publishes the change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isSavingServer = false
            withAnimation(.easeInOut(duration: 0.2)) {
                isEditingServer = false
            }
            serverDraft = ""
        }
    }

    /// Info pill rendered in dark-on-lime style, with optional trailing icon
    /// (used by the server pill to hint it's editable).
    private func infoPillContent(icon: String, text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 9))
                .lineLimit(1)
            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 7))
                    .opacity(0.8)
            }
        }
        .foregroundColor(Self.cardText.opacity(0.7))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Self.cardText.opacity(0.1)))
    }

    private func refreshLinkedDevices() async {
        guard let conn = SyncManager.shared.connection else { return }
        linkedDevices = await conn.fetchLinkedDevices()
    }

    private func unlinkDevice(_ device: ServerConnection.LinkedDeviceInfo) async {
        guard let conn = SyncManager.shared.connection else { return }
        isUnlinking = device.id
        do {
            try await conn.unlinkDevice(device.id)
            linkedDevices.removeAll { $0.id == device.id }
        } catch {
            // Silently ignore — device might already be unlinked
        }
        isUnlinking = nil
    }

    private func generateQRCode() {
        // No point generating a QR when the host isn't set — the pairing
        // screen already tells the user to configure one in Settings.
        guard let url = serverUrl else {
            qrImage = nil
            return
        }
        // R2.7 dual QR: embed the monitoring shortCode AND (when an in-app
        // enrollment is in flight) the enrollment intent the daemon is polling,
        // so one scan does both. kind reflects which parts are present.
        guard let payload = PairQRPayload.make(
            serverUrl: url,
            shortCode: shortCode,
            enrollIntent: enroller.intent
        ) else { return }
        qrImage = PairQRPayload.qrImage(from: payload)
    }
}

// MARK: - Inline Pair iPhone Panel
//
// Displayed directly in the notch plugin panel (no popup). When a server
// is not yet configured, the screen is dominated by the server-config
// prompt so users cannot silently skip it (issue #57). Once a server is
// set, the QR + short code + linked devices list takes over.

struct PairPhonePanelView: View {
    @ObservedObject private var syncManager = SyncManager.shared
    @ObservedObject private var enroller = MioAgentEnroller.shared
    @State private var serverDraft = ""
    @State private var isSavingServer = false
    @State private var isEditingServer = false
    @State private var qrImage: NSImage?
    @State private var deviceName = Host.current().localizedName ?? "Mac"
    @State private var linkedDevices: [ServerConnection.LinkedDeviceInfo] = []
    @State private var isUnlinking: String? = nil
    private var theme: ThemeResolver { pairPhoneTheme() }

    private var serverUrl: String? {
        let value = SyncManager.shared.serverUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    private var shortCode: String? { syncManager.shortCode }

    private var isValidDraft: Bool {
        let s = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && (u.host?.isEmpty == false)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerRow

                if let url = serverUrl, !isEditingServer {
                    pairingSection(serverUrl: url)
                } else {
                    serverConfigSection
                }
            }
            .padding(.horizontal, 24)
            // Top inset ~44pt keeps content clear of the floating back
            // button pill (PluginContentView overlays it at top-left).
            // Bottom stays at the spec 16pt.
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // #118: one QR = monitoring + workspace by default (see QRPairingContentView).
            enroller.ensureWorkspaceIntentForQR(serverUrl: serverUrl)
            generateQRCode()
            Task { await refreshLinkedDevices() }
        }
        .onChange(of: shortCode) { _, _ in generateQRCode() }
        .onChange(of: enroller.intent) { _, _ in generateQRCode() }
        .onChange(of: syncManager.connectionState) { _, _ in
            Task { await refreshLinkedDevices() }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
            Text("Pair iPhone")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Spacer()
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch syncManager.connectionState {
        case .connected:
            HStack(spacing: 5) {
                Circle().fill(theme.doneColor).frame(width: 6, height: 6)
                Text(L10n.pairPanelOnline)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.doneColor)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(theme.doneColor.opacity(0.12)))
        case .connecting, .authenticating:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text(L10n.pairPanelConnecting)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(theme.overlay.opacity(0.18)))
        case .error(let msg):
            HStack(spacing: 5) {
                Circle().fill(theme.errorColor).frame(width: 6, height: 6)
                Text(msg)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(theme.errorColor.opacity(0.12)))
        case .disconnected:
            HStack(spacing: 5) {
                Circle().fill(theme.mutedText).frame(width: 6, height: 6)
                Text(L10n.pairPanelNotConnected)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.mutedText)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(theme.overlay.opacity(0.18)))
        }
    }

    // MARK: - Server config (dominant when unset)

    private var serverConfigSection: some View {
        VStack(spacing: 14) {
            // Big server icon
            ZStack {
                Circle()
                    .fill(theme.overlay.opacity(0.16))
                    .frame(width: 72, height: 72)
                Image(systemName: "server.rack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.top, 4)

            Text(L10n.pairPanelStepServerTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Text(L10n.pairPanelStepServerBody)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            TextField(L10n.pairPanelServerPlaceholder, text: $serverDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.overlay.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.border.opacity(0.9), lineWidth: 0.5)
                )
                .disabled(isSavingServer)

            HStack(spacing: 8) {
                if isEditingServer && serverUrl != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isEditingServer = false
                            serverDraft = ""
                        }
                    } label: {
                        Text(L10n.pairPanelCancel)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundColor(theme.secondaryText)
                            .background(RoundedRectangle(cornerRadius: 8).fill(theme.overlay.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    saveServerURL()
                } label: {
                    HStack(spacing: 6) {
                        if isSavingServer {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                        }
                        Text(isSavingServer
                             ? L10n.pairPanelConnecting
                             : (isEditingServer ? L10n.pairPanelSave : L10n.pairPanelSaveAndConnect))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundColor(isValidDraft ? theme.inverseText : theme.mutedText)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isValidDraft ? theme.primaryText.opacity(0.92) : theme.overlay.opacity(0.18))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isValidDraft || isSavingServer)
            }

            Text(L10n.pairPanelStoredLocally)
                .font(.system(size: 10))
                .foregroundColor(theme.mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            .padding(.top, 2)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.overlay.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.border.opacity(0.8), lineWidth: 0.5)
        )
    }

    // MARK: - Paired / ready-to-pair section

    @ViewBuilder
    private func pairingSection(serverUrl url: String) -> some View {
        VStack(spacing: 12) {
            scanHeader
            qrBlock
            shortCodeBlock
            serverInfoRow(url: url)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.overlay.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.border.opacity(0.7), lineWidth: 0.5))
    }

    private var scanHeader: some View {
        VStack(spacing: 4) {
            Text(L10n.pairPanelStepScanTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            // #118: reflect that one scan pairs monitoring + workspace when the QR
            // carries an enrollment intent (the default for an enrollable Mac).
            Text(enroller.intent != nil ? L10n.pairPanelStepScanBodyBoth : L10n.pairPanelStepScanBody)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var qrBlock: some View {
        if let qrImage {
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        } else {
            VStack(spacing: 8) {
                ProgressView().tint(theme.mutedText)
                Text(L10n.pairPanelGeneratingCode)
                    .font(.system(size: 10))
                    .foregroundColor(theme.mutedText)
            }
            .frame(width: 180, height: 180)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.overlay.opacity(0.16)))
        }
    }

    private var shortCodeBlock: some View {
        VStack(spacing: 4) {
            Text(L10n.pairPanelShortCodeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.mutedText)
            Text(shortCode ?? "------")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundColor(theme.primaryText.opacity(shortCode == nil ? 0.3 : 0.95))
        }
    }

    private func serverInfoRow(url: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.pairPanelServerLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.mutedText)
                    Text(URL(string: url)?.host ?? url)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    serverDraft = url
                    withAnimation(.easeInOut(duration: 0.18)) { isEditingServer = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L10n.pairPanelChangeServer)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.overlay.opacity(0.22))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(theme.border.opacity(0.9), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(L10n.pairPanelChangeServerTooltip)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.overlay.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.border.opacity(0.8), lineWidth: 0.5)
            )

            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 9))
                Text("\(L10n.pairPanelDeviceLabel) · \(deviceName)")
                    .font(.system(size: 10))
            }
            .foregroundColor(theme.mutedText)
            .padding(.top, 6)
        }
    }

    private var linkedDevicesBlock: some View {
        VStack(spacing: 4) {
            HStack {
                Text(L10n.pairPanelLinkedDevices)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.mutedText)
                Spacer()
                Text("\(linkedDevices.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.mutedText)
            }
            .padding(.horizontal, 4).padding(.bottom, 2)

            ForEach(linkedDevices) { device in
                linkedDeviceRow(device)
            }
        }
        .padding(.top, 4)
    }

    private func linkedDeviceRow(_ device: ServerConnection.LinkedDeviceInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: device.kind == "iphone" ? "iphone" : "desktopcomputer")
                .font(.system(size: 10))
                .foregroundColor(theme.secondaryText)
            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
            Spacer()
            Button {
                Task { await unlinkDevice(device) }
            } label: {
                if isUnlinking == device.id {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.mutedText)
                }
            }
            .buttonStyle(.plain)
            .disabled(isUnlinking != nil)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.overlay.opacity(0.16)))
    }

    private func pillContent(icon: String, text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10)).lineLimit(1)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 8)).opacity(0.7)
            }
        }
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(theme.overlay.opacity(0.18)))
    }

    // MARK: - Actions

    private func saveServerURL() {
        let s = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidDraft else { return }
        isSavingServer = true
        SyncManager.shared.serverUrl = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isSavingServer = false
            withAnimation(.easeInOut(duration: 0.2)) { isEditingServer = false }
            serverDraft = ""
        }
    }

    private func refreshLinkedDevices() async {
        guard let conn = SyncManager.shared.connection else { return }
        linkedDevices = await conn.fetchLinkedDevices()
    }

    private func unlinkDevice(_ device: ServerConnection.LinkedDeviceInfo) async {
        guard let conn = SyncManager.shared.connection else { return }
        isUnlinking = device.id
        do {
            try await conn.unlinkDevice(device.id)
            linkedDevices.removeAll { $0.id == device.id }
        } catch {
            // ignore
        }
        isUnlinking = nil
    }

    private func generateQRCode() {
        guard let url = serverUrl else {
            qrImage = nil
            return
        }
        // R2.7 dual QR — see QRPairingContentView.generateQRCode for the contract.
        guard let payload = PairQRPayload.make(
            serverUrl: url,
            shortCode: shortCode,
            enrollIntent: enroller.intent
        ) else { return }
        qrImage = PairQRPayload.qrImage(from: payload)
    }
}
