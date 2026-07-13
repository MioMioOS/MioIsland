//
//  SyncManager.swift
//  ClaudeIsland
//
//  Top-level coordinator for CodeLight Server sync.
//  Manages connection lifecycle, message relay, and RPC execution.
//

import Combine
import Foundation
import os.log

/// Coordinates all CodeLight Server sync functionality.
/// Initialize once at app startup, connects/disconnects based on configuration.
@MainActor
final class SyncManager: ObservableObject {

    static let shared = SyncManager()
    static let logger = Logger(subsystem: "com.codeisland", category: "SyncManager")

    @Published private(set) var isEnabled = false
    @Published private(set) var connectionState: ServerConnectionState = .disconnected

    private(set) var connection: ServerConnection?
    private var relay: MessageRelay?
    private var rpcExecutor: RPCExecutor?
    private var capabilityTimer: Timer?
    private var projectUploadTimer: Timer?

    /// Re-publishes the underlying ServerConnection.shortCode so SwiftUI views
    /// (PairPhoneView) can observe it via SyncManager directly.
    @Published private(set) var shortCode: String?

    /// Most recent successful trial redemption on this Mac. Local-only,
    /// kept as a "just-now" cache so the banner shows instantly after
    /// `redeemCode` returns — without waiting for the server's socket
    /// push or a refetch. SubscriptionState (server truth) takes over
    /// once the server responds.
    @Published private(set) var lastRedemption: RedemptionRecord?

    /// Server-truth subscription state for this Mac. Populated by:
    ///   1. fetchSubscription() on connect (GET /v1/subscription/status)
    ///   2. socket "subscription-updated" event (push from server)
    ///   3. Local construction from a successful redeem response
    /// The Pair Phone banner reads this preferentially; lastRedemption
    /// is only the fallback for the post-redeem instant when the server
    /// hasn't echoed the new state yet.
    @Published private(set) var subscription: SubscriptionState?

    /// Persistence keys namespaced by the current server's host. Without
    /// this, switching from one CodeLight server to another would leave
    /// the old server's "试用中 · 剩余 3 天" banner showing on the new
    /// connection. Both keys (redemption + subscription) get the same
    /// host bucket so they stay aligned.
    private static let lastRedemptionKeyPrefix = "MioIsland.lastRedemption."
    private static let subscriptionKeyPrefix = "MioIsland.subscription."

    private func currentRedemptionKey() -> String {
        return "\(Self.lastRedemptionKeyPrefix)\(serverHost())"
    }

    private func currentSubscriptionKey() -> String {
        return "\(Self.subscriptionKeyPrefix)\(serverHost())"
    }

    private func serverHost() -> String {
        serverUrl.flatMap { URL(string: $0)?.host?.lowercased() } ?? "unknown"
    }

    /// Text the phone injected into a Claude session via cmux. Used so MessageRelay
    /// can skip re-uploading the same text when it re-appears in the JSONL (dedup).
    /// Keyed by Claude session UUID; entries expire after 60s.
    private var recentlyInjected: [String: [(text: String, at: Date)]] = [:]

    func recordPhoneInjection(claudeUuid: String, text: String) {
        pruneInjections()
        recentlyInjected[claudeUuid, default: []].append((text, Date()))
    }

    /// Returns true and removes the entry if `text` was recently injected from phone.
    func consumePhoneInjection(claudeUuid: String, text: String) -> Bool {
        pruneInjections()
        guard var list = recentlyInjected[claudeUuid] else { return false }
        if let idx = list.firstIndex(where: { $0.text == text }) {
            list.remove(at: idx)
            recentlyInjected[claudeUuid] = list.isEmpty ? nil : list
            return true
        }
        return false
    }

    private func pruneInjections() {
        let cutoff = Date().addingTimeInterval(-60)
        for (k, v) in recentlyInjected {
            let kept = v.filter { $0.at > cutoff }
            recentlyInjected[k] = kept.isEmpty ? nil : kept
        }
    }

    /// The server URL to connect to. Stored in UserDefaults.
    var serverUrl: String? {
        get { UserDefaults.standard.string(forKey: "codelight-server-url") }
        set {
            UserDefaults.standard.set(newValue, forKey: "codelight-server-url")
            // Re-key the persisted state to the new host so we never
            // display the previous server's trial state on a fresh
            // connection. Reloads from the new host's bucket (or clears
            // when no record exists yet).
            loadPersistedRedemption()
            loadPersistedSubscription()
            if let url = newValue, !url.isEmpty {
                Task { await connectToServer(url: url) }
            } else {
                disconnectFromServer()
            }
        }
    }

    private init() {
        // No hardcoded server URL on fresh install — the user must configure
        // their own CodeLight server URL in Settings before pairing. This
        // avoids accidentally routing every user's sessions through the
        // author's personal host.
        loadPersistedRedemption()
        loadPersistedSubscription()
        if let url = serverUrl, !url.isEmpty {
            Task { await connectToServer(url: url) }
        }
    }

    // MARK: - Connection Lifecycle

    func connectToServer(url: String) async {
        disconnectFromServer()

        let conn = ServerConnection(serverUrl: url)
        self.connection = conn

        do {
            try await conn.authenticate()
            conn.connect()

            // Handle messages from phone → type into terminal
            conn.onUserMessage = { [weak self] serverSessionId, messageText, claudeUuid, cwd in
                Task { @MainActor in
                    await self?.handlePhoneMessage(serverSessionId: serverSessionId, text: messageText, claudeUuid: claudeUuid, cwd: cwd)
                }
            }

            // Phone unpaired this Mac → log + future: clean up local state
            conn.onLinkRemoved = { [weak self] sourceDeviceId in
                Task { @MainActor in
                    Self.logger.info("iPhone \(sourceDeviceId.prefix(8), privacy: .public) unpaired from this Mac")
                    self?.objectWillChange.send()
                }
            }

            // Phone requested a remote session launch → spawn cmux subprocess
            conn.onSessionLaunch = { presetId, projectPath, requestedBy in
                Task { @MainActor in
                    let ok = LaunchService.shared.launch(presetId: presetId, projectPath: projectPath)
                    Self.logger.info("session-launch from \(requestedBy.prefix(8), privacy: .public): \(ok ? "ok" : "failed")")
                }
            }

            // Server pushed a subscription update (redeem-code complete,
            // IAP renewal, admin grant). Apply it as authoritative —
            // server is the source of truth for subscription state.
            conn.onSubscriptionUpdated = { [weak self] state in
                Task { @MainActor in
                    self?.applySubscription(state, source: "socket")
                }
            }

            // Wait for socket to actually connect before starting relay
            let relay = MessageRelay(connection: conn)
            self.relay = relay
            let rpc = RPCExecutor()
            self.rpcExecutor = rpc

            // Delay relay start to give socket time to connect
            Task { @MainActor in
                // Wait up to 5 seconds for socket connection
                for _ in 0..<50 {
                    if conn.isConnected { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                if conn.isConnected {
                    relay.startRelaying()
                    Self.logger.info("Relay started after socket connected")
                } else {
                    Self.logger.warning("Socket did not connect in time, starting relay anyway")
                    relay.startRelaying()
                }
            }

            isEnabled = true
            connectionState = .connected
            Self.logger.info("Sync enabled with \(url)")

            // Register this Mac with the server (lazy-allocates permanent shortCode).
            let macName = Host.current().localizedName ?? "Mac"
            await conn.registerDevice(name: macName, kind: "mac")
            self.shortCode = conn.shortCode

            // Push current preset list to the server so the phone can browse them.
            await uploadPresets()

            // Scan local capabilities and push to server so the phone can browse
            // available slash commands, skills, and MCP servers. Then refresh every
            // 10 minutes in case the user installs new plugins.
            scheduleCapabilityUploads()

            // Periodically upload known project paths so the phone can pick from
            // recent projects when launching a session.
            scheduleProjectUploads()

            // Pull current subscription state from the server. Pre-F4
            // server short-circuits Mac to {status:'none'} — applySubscription
            // handles that case by keeping any recent local lastRedemption
            // visible. Post-F4: server returns Mac's own trial state.
            // Failures are non-fatal: keep prior state, retry next connect.
            Task { [weak self] in
                guard let self else { return }
                do {
                    if let state = try await conn.fetchSubscription() {
                        await MainActor.run {
                            self.applySubscription(state, source: "fetch")
                        }
                    }
                } catch {
                    Self.logger.warning("initial fetchSubscription failed: \(error.localizedDescription)")
                }
            }
        } catch {
            connectionState = .error(error.localizedDescription)
            Self.logger.error("Sync connection failed: \(error)")
        }
    }

    /// Handle a user message received from the phone — type it into the matching terminal.
    /// Tries the locally tracked SessionState first; falls back to direct cmux lookup
    /// using the Claude UUID/path the server provides (so dormant sessions still work).
    private func handlePhoneMessage(serverSessionId: String, text: String, claudeUuid: String?, cwd: String?) async {
        let sessions = await SessionStore.shared.currentSessions()
        let localId = self.relay?.localSessionId(forServerId: serverSessionId)
        let preview = String(text.prefix(200))
        Self.logger.info("handlePhoneMessage: serverId=\(serverSessionId, privacy: .public) localId=\(localId ?? "nil", privacy: .public) tag=\(claudeUuid ?? "nil", privacy: .public) cwd=\(cwd ?? "nil", privacy: .public) raw=\(preview, privacy: .public)")

        // Resolve target identity ONCE up front and share across all paths
        // (control key / image / slash command / text). When SessionStore is
        // tracking this conversation, lift the live Claude PID off it — that's
        // the single most reliable identity for cmux routing because it was
        // captured from `os.getppid()` inside the hook script. Falls back to
        // server-provided UUID + cwd when not tracked.
        let trackedSession = localId.flatMap { id in sessions.first(where: { $0.sessionId == id }) }
        let targetUuid: String? = trackedSession?.sessionId ?? claudeUuid
        let livePid: Int? = trackedSession?.pid
        // cmux IDs captured by hook script from os.environ — the only reliable
        // way to route on modern macOS where `ps -E` hides env vars.
        let cmuxWsId: String? = trackedSession?.cmuxWorkspaceId
        let cmuxSurfId: String? = trackedSession?.cmuxSurfaceId

        // Parse the message content — it may be plain text OR a JSON envelope with images.
        let (parsedText, imageBlobIds) = parseMessagePayload(text)

        // Read-screen path: phone explicitly sends `{type:"read-screen"}` to snapshot
        // the current cmux tab's buffer. Fire-and-forget — we ship the captured text
        // back as a synthetic terminal_output message, same pipeline as slash commands.
        if isReadScreenRequest(text) {
            if let uuid = targetUuid {
                let snapshot = await TerminalWriter.shared.readScreen(claudeUuid: uuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWsId, cmuxSurfaceId: cmuxSurfId, terminalApp: trackedSession?.terminalApp)
                if let snapshot, !snapshot.isEmpty {
                    await sendTerminalOutputMessage(sessionId: serverSessionId, command: "read-screen", output: snapshot)
                }
                Self.logger.info("Phone read-screen (uuid=\(uuid.prefix(8), privacy: .public) pid=\(livePid?.description ?? "nil", privacy: .public) term=\(trackedSession?.terminalApp ?? "nil", privacy: .public)) → captured=\(snapshot != nil)")
            } else {
                Self.logger.warning("read-screen dropped: no target uuid")
            }
            return
        }

        // Control-key path: phone explicitly sends `{type:"key", key:"escape"}` etc.
        // These don't go through stdin — we fire them directly at the cmux surface.
        if let controlKey = parseControlKey(text) {
            if let uuid = targetUuid {
                let ok = await TerminalWriter.shared.sendControlKey(controlKey, claudeUuid: uuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWsId, cmuxSurfaceId: cmuxSurfId, terminalApp: trackedSession?.terminalApp)
                Self.logger.info("Phone control key '\(controlKey, privacy: .public)' (uuid=\(uuid.prefix(8), privacy: .public) pid=\(livePid?.description ?? "nil", privacy: .public)) → \(ok ? "success" : "failed")")
                if !ok {
                    PhoneMessageFailureNotifier.notify(
                        reason: "control-key",
                        detail: "\(L10n.phoneMsgFailInject) [key=\(controlKey) uuid=\(uuid.prefix(8)) term=\(trackedSession?.terminalApp ?? "?")]"
                    )
                }
            } else {
                Self.logger.warning("Control key dropped: no target uuid")
                PhoneMessageFailureNotifier.notify(reason: "no-session", detail: L10n.phoneMsgFailNoSession)
            }
            return
        }
        Self.logger.info("parsed: text=\(parsedText.prefix(80), privacy: .public) blobCount=\(imageBlobIds.count)")

        // Image path: download blobs and paste via NSPasteboard + Cmd+V
        if !imageBlobIds.isEmpty {
            guard let targetUuid, let connection = self.connection else {
                Self.logger.warning("Phone image message dropped: no target uuid")
                return
            }
            var images: [Data] = []
            for blobId in imageBlobIds {
                do {
                    let (data, _) = try await connection.downloadBlob(blobId: blobId)
                    images.append(data)
                    // Ack so the server can delete the blob immediately
                    connection.sendBlobConsumed(blobId: blobId)
                } catch {
                    Self.logger.error("Failed to download blob \(blobId): \(error.localizedDescription)")
                }
            }
            if images.isEmpty {
                Self.logger.warning("No images could be downloaded — falling back to text-only")
                DebugLogger.log("PhoneMsg", "image blobs failed to download (\(imageBlobIds.count)) — falling back to text-only")
            } else {
                let ok = await TerminalWriter.shared.sendImagesAndText(images: images, text: parsedText, claudeUuid: targetUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWsId, cmuxSurfaceId: cmuxSurfId, terminalApp: trackedSession?.terminalApp)
                if ok { recordPhoneInjection(claudeUuid: targetUuid, text: parsedText) }
                Self.logger.info("Phone message with \(images.count) image(s) → terminal: \(ok ? "success" : "failed")")
                if !ok {
                    PhoneMessageFailureNotifier.notify(
                        reason: "image-inject",
                        detail: "\(L10n.phoneMsgFailInject) [images=\(images.count) uuid=\(targetUuid.prefix(8)) term=\(trackedSession?.terminalApp ?? "?")]"
                    )
                }
                return
            }
        }

        // Slash-command path: Claude's built-in commands (/usage, /cost, /model, etc.)
        // don't emit hook events, so their output never hits the JSONL and the phone
        // wouldn't otherwise see the response. We snapshot the pane, inject the
        // command, wait, snapshot again, diff, and ship the new lines back as a
        // synthetic terminal_output message.
        if parsedText.hasPrefix("/"), let targetUuid {
            let output = await TerminalWriter.shared.sendSlashCommandAndCaptureOutput(parsedText, claudeUuid: targetUuid, cwd: cwd, livePid: livePid, cmuxWorkspaceId: cmuxWsId, cmuxSurfaceId: cmuxSurfId, terminalApp: trackedSession?.terminalApp)
            if let output {
                // Command was sent and output captured (may be empty if no visible change)
                recordPhoneInjection(claudeUuid: targetUuid, text: parsedText)
                if !output.isEmpty {
                    await sendTerminalOutputMessage(sessionId: serverSessionId, command: parsedText, output: output)
                }
                Self.logger.info("Phone slash command /\(parsedText.dropFirst().prefix(20)) → captured")
                return
            }
            // cmux target not found — fall through to plain text path for non-cmux terminals
            Self.logger.info("Slash command /\(parsedText.dropFirst().prefix(20)) capture unavailable, sending as text")
        }

        // Plain text path — uses the unified target identity computed at the top.
        let termApp = trackedSession?.terminalApp
        if let uuid = targetUuid {
            let sent = await TerminalWriter.shared.sendTextDirect(
                parsedText,
                claudeUuid: uuid,
                cwd: cwd,
                livePid: livePid,
                cmuxWorkspaceId: cmuxWsId,
                cmuxSurfaceId: cmuxSurfId,
                terminalApp: termApp
            )
            if sent { recordPhoneInjection(claudeUuid: uuid, text: parsedText) }
            Self.logger.info("Phone message → terminal (uuid=\(uuid.prefix(8), privacy: .public) pid=\(livePid?.description ?? "nil", privacy: .public)): \(sent ? "success" : "failed")")
            if !sent {
                PhoneMessageFailureNotifier.notify(
                    reason: "text-inject",
                    detail: "\(L10n.phoneMsgFailInject) [uuid=\(uuid.prefix(8)) term=\(termApp ?? "?") pid=\(livePid?.description ?? "-")]"
                )
            }
            return
        }

        Self.logger.warning("Phone message dropped: no local session and no uuid for serverId=\(serverSessionId, privacy: .public)")
        PhoneMessageFailureNotifier.notify(
            reason: "no-session",
            detail: "\(L10n.phoneMsgFailNoSession) [serverId=\(serverSessionId.prefix(8))]"
        )
    }

    // MARK: - Capability Upload

    /// Scan the local filesystem for capabilities and push to the server now, then
    /// refresh every 10 minutes. Passes the most recent session's cwd so project-local
    /// commands/skills get included.
    private func scheduleCapabilityUploads() {
        capabilityTimer?.invalidate()
        Task { [weak self] in await self?.uploadCapabilitiesNow() }
        capabilityTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.uploadCapabilitiesNow() }
        }
    }

    private func uploadCapabilitiesNow() async {
        guard let connection = self.connection else { return }
        // Pick a project path from the most recent session (if any) so project-local
        // commands/skills get scanned too.
        let sessions = await SessionStore.shared.currentSessions()
        let projectPath = sessions.first?.cwd
        let snapshot = CapabilityScanner.scan(projectPath: projectPath)
        await connection.uploadCapabilities(snapshot)
        Self.logger.info("Uploaded capability snapshot (project=\(projectPath ?? "-"))")
    }

    // MARK: - Preset / Project Upload

    /// Push the current preset list to the server. Called on connect and on every preset mutation.
    func uploadPresets() async {
        guard let connection = self.connection else { return }
        let payload = PresetStore.shared.presets.map { $0.serverPayload }
        await connection.uploadPresets(payload)
        Self.logger.info("Uploaded \(payload.count) presets")
    }

    /// Schedule periodic uploads of known project paths (every 5 minutes).
    private func scheduleProjectUploads() {
        projectUploadTimer?.invalidate()
        Task { [weak self] in await self?.uploadProjectsNow() }
        projectUploadTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.uploadProjectsNow() }
        }
    }

    private func uploadProjectsNow() async {
        guard let connection = self.connection else { return }
        let sessions = await SessionStore.shared.currentSessions()

        // Dedupe by cwd, prefer the entry whose projectName is non-empty.
        var byPath: [String: String] = [:]
        for s in sessions {
            let cwd = s.cwd
            guard !cwd.isEmpty else { continue }
            let name = s.projectName.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : s.projectName
            byPath[cwd] = name
        }

        let projects = byPath.map { (path, name) in
            ["path": path, "name": name]
        }
        guard !projects.isEmpty else { return }

        await connection.uploadProjects(projects)
        Self.logger.info("Uploaded \(projects.count) project paths")
    }

    /// Emit a synthetic `terminal_output` message on behalf of the user's session,
    /// so the phone can render the captured response to a slash command.
    private func sendTerminalOutputMessage(sessionId: String, command: String, output: String) async {
        guard let connection = self.connection, connection.isConnected else { return }
        let payload: [String: Any] = [
            "type": "terminal_output",
            "command": command,
            "text": output,
            "timestamp": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let localId = "term-\(UUID().uuidString)"
        connection.sendMessage(sessionId: sessionId, content: json, localId: localId)
    }

    /// True if the message is a `{type:"read-screen"}` envelope from the phone.
    private func isReadScreenRequest(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (dict["type"] as? String) == "read-screen"
    }

    /// Extract a control key name from a message payload of shape `{type:"key", key:"escape"}`.
    /// Returns nil if the message isn't a control-key envelope.
    private func parseControlKey(_ content: String) -> String? {
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["type"] as? String) == "key",
              let key = dict["key"] as? String
        else { return nil }
        return key
    }

    /// Extract `text` and `images[].blobId` from a message content string. If the content
    /// isn't a JSON object, treat it as plain text with no images.
    private func parseMessagePayload(_ content: String) -> (text: String, blobIds: [String]) {
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (content, [])
        }
        let text = dict["text"] as? String ?? ""
        var blobIds: [String] = []
        if let images = dict["images"] as? [[String: Any]] {
            blobIds = images.compactMap { $0["blobId"] as? String }
        }
        return (text, blobIds)
    }

    func disconnectFromServer() {
        relay?.stopRelaying()
        connection?.disconnect()
        connection = nil
        relay = nil
        rpcExecutor = nil
        capabilityTimer?.invalidate()
        capabilityTimer = nil
        projectUploadTimer?.invalidate()
        projectUploadTimer = nil
        shortCode = nil
        isEnabled = false
        connectionState = .disconnected
    }

    /// Called when a QR code is scanned with server details
    func handlePairingQR(serverUrl: String, tempPublicKey: String, deviceName: String) async {
        UserDefaults.standard.set(serverUrl, forKey: "codelight-server-url")
        await connectToServer(url: serverUrl)
        Self.logger.info("Paired with \(deviceName) via QR")
    }

    // MARK: - Redeem code (trial activation)

    /// Activate a trial code on this Mac. Trims + uppercases the input
    /// then delegates to `ServerConnection.redeemPairingCode`. On
    /// success persists the record so the banner survives relaunches.
    /// Throws `RedeemError.unauthorized` (or `.network`) without
    /// hitting the wire when we have no live connection.
    func redeemCode(_ raw: String) async throws -> RedemptionRecord {
        let code = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !code.isEmpty else {
            throw RedeemError.invalidCode
        }
        guard let connection else {
            // No connection object means no server URL configured. UI
            // should already block this with its connectionState gate
            // but throw something sensible just in case.
            throw RedeemError.unauthorized
        }
        let record = try await connection.redeemPairingCode(code)
        self.lastRedemption = record
        persistRedemption(record)
        // Construct a SubscriptionState from the redeem response so the
        // banner shows the new trial instantly without waiting for the
        // server's socket push to land. The push (server F3) will overwrite
        // this with server-computed daysLeft, but the values converge — same
        // expiresAt, same trial. Without this, there's a 1-3s window where
        // Mac shows nothing after a successful redeem.
        let derived = SubscriptionState(fromRedemption: record)
        applySubscription(derived, source: "redeem")
        Self.logger.info("Trial activated: \(record.durationDays)d, expires \(record.expiresAt, privacy: .public)")
        return record
    }

    /// Force-refresh subscription state from the server. Called by the
    /// Pair Phone view's .onAppear so opening the panel always shows
    /// current state — covers the case where the trial expired while
    /// the panel was closed and there was no socket event to wake us
    /// (e.g., admin SQL set expiry, no code path emitted the event).
    /// Failures are swallowed: keep the prior cached state visible
    /// rather than wiping the banner on a transient network blip.
    func refreshSubscription() async {
        Self.logger.info("manual refresh triggered, hasConnection=\(self.connection != nil)")
        guard let connection else {
            Self.logger.warning("manual refresh skipped: no connection — SyncManager not connected yet")
            return
        }
        do {
            if let state = try await connection.fetchSubscription() {
                applySubscription(state, source: "manual-refresh")
            } else {
                Self.logger.warning("manual refresh: fetchSubscription returned nil")
            }
        } catch {
            Self.logger.warning("manual refreshSubscription failed: \(error.localizedDescription)")
        }
    }

    /// Apply a new subscription state. Server is the source of truth
    /// post-F4 — whatever it returns wins, including 'none' (no trial)
    /// and 'expired' (trial ended). Earlier versions had an
    /// anti-regression guard to keep local state when server returned
    /// 'none', built for the pre-F4 era when Mac calls were
    /// short-circuited. F4 is now live; that guard reverses into a
    /// stale-state trap (admin SQL clears the trial → server returns
    /// 'none' → guard refuses to clear local → banner stuck on a trial
    /// that no longer exists). Trust the server.
    func applySubscription(_ state: SubscriptionState, source: String) {
        self.subscription = state
        persistSubscription(state)
        Self.logger.info("subscription applied: status=\(state.status.rawValue, privacy: .public) daysLeft=\(state.daysLeft ?? -1) source=\(source, privacy: .public)")
    }

    // MARK: - Persistence helpers

    private func loadPersistedRedemption() {
        let key = currentRedemptionKey()
        guard let data = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder.iso8601().decode(RedemptionRecord.self, from: data) else {
            self.lastRedemption = nil
            return
        }
        self.lastRedemption = record
    }

    private func persistRedemption(_ record: RedemptionRecord) {
        guard let data = try? JSONEncoder.iso8601().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: currentRedemptionKey())
    }

    private func loadPersistedSubscription() {
        let key = currentSubscriptionKey()
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder.iso8601().decode(SubscriptionState.self, from: data) else {
            self.subscription = nil
            return
        }
        self.subscription = state
    }

    private func persistSubscription(_ state: SubscriptionState) {
        guard let data = try? JSONEncoder.iso8601().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: currentSubscriptionKey())
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
