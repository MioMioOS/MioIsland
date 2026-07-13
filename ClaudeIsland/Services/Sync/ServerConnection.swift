//
//  ServerConnection.swift
//  ClaudeIsland
//
//  Manages the connection to a CodeLight Server.
//  Handles auth, Socket.io lifecycle, and reconnection.
//

import Combine
import Foundation
import os.log
import CodeLightCrypto
import CodeLightProtocol
import SocketIO

/// Connection state for a CodeLight Server
enum ServerConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case error(String)
}

/// Manages connection to a single CodeLight Server instance.
@MainActor
final class ServerConnection: ObservableObject {

    static let logger = Logger(subsystem: "com.codeisland", category: "ServerConnection")

    @Published private(set) var state: ServerConnectionState = .disconnected

    private let serverUrl: String
    private let keyManager: KeyManager
    private var token: String?
    private(set) var deviceId: String?
    /// This Mac's permanent shortCode, populated by `registerDevice`. Lazy-allocated server-side.
    @Published private(set) var shortCode: String?
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var crypto: MessageCrypto?

    /// Called when an RPC request arrives from the phone
    var onRpcCall: ((String, String, @escaping (String) -> Void) -> Void)?

    /// Called when a user message arrives from another device (phone)
    var onUserMessage: ((String, String, String?, String?) -> Void)?  // (serverSessionId, messageText, claudeUuid, cwd)

    /// Called when an iPhone unpairs this Mac. Payload: source iPhone's deviceId.
    var onLinkRemoved: ((String) -> Void)?

    /// Called when an iPhone requests a remote session launch. Payload: (presetId, projectPath, requestedByDeviceId).
    var onSessionLaunch: ((String, String, String) -> Void)?

    /// Called when the server pushes a `subscription-updated` event for
    /// THIS Mac. Server's emit fires after redeem-code, IAP renewal,
    /// admin grant, or any other state change. Mac uses this for live
    /// banner refresh without polling.
    /// Pre-server-F3: this event only goes to paired iPhones, never to
    /// the Mac itself, so this handler stays silent. Post-F3: Mac is in
    /// the recipient list and the banner auto-updates.
    var onSubscriptionUpdated: ((SubscriptionState) -> Void)?

    var isConnected: Bool { state == .connected }

    init(serverUrl: String, keyManager: KeyManager = KeyManager(serviceName: "com.codeisland.keys")) {
        self.serverUrl = serverUrl
        self.keyManager = keyManager
        self.token = keyManager.loadToken(forServer: serverUrl)
    }

    // MARK: - Client version gate (cross-platform contract)

    /// Header value advertising this client's platform + semver. The
    /// server uses it for Phase 1 observation (version distribution) and
    /// Phase 2 enforcement (HTTP 426 on too-old clients).
    ///
    /// Pre-release suffixes are stripped (e.g. "2.4.0-tf1" -> "mac/2.4.0")
    /// so TestFlight / debug builds aren't accidentally classified as
    /// older than their underlying release version.
    static let clientVersionHeaderValue: String = {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let base = raw.split(separator: "-").first.map(String.init) ?? raw
        return "mac/\(base)"
    }()

    /// Apply the `X-Client-Version` header to every outbound URLRequest.
    /// Called from a single helper so we can't forget on new endpoints.
    private func addClientHeaders(to request: inout URLRequest) {
        request.setValue(Self.clientVersionHeaderValue, forHTTPHeaderField: "X-Client-Version")
    }

    /// Intercept HTTP 426 client_too_old before any endpoint-specific
    /// body parsing. The alert pops once per cooldown window (handled by
    /// UpgradeRequiredCoordinator), then RedeemError.clientTooOld is
    /// thrown so callers stop their flow (no retry, no body parse, no
    /// fallback path). Non-426 responses pass through untouched.
    private func check426(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 426 else { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (json?["error"] as? String) == "client_too_old" else { return }
        let downloadUrl = (json?["downloadUrl"] as? String) ?? "https://miomioos.github.io/MioIsland/"
        let message = json?["message"] as? String
        UpgradeRequiredCoordinator.shared.show(downloadUrl: downloadUrl, serverMessage: message)
        Self.logger.warning("Server returned 426 client_too_old — clientVersion=\(Self.clientVersionHeaderValue, privacy: .public)")
        throw RedeemError.clientTooOld
    }

    // MARK: - Authentication

    func authenticate() async throws {
        state = .authenticating

        let _ = try keyManager.getOrCreateIdentityKey()

        let challenge = UUID().uuidString
        let challengeData = Data(challenge.utf8)
        let signature = try keyManager.sign(challengeData)
        let publicKey = try keyManager.publicKeyBase64()

        let request = AuthRequest(
            publicKey: publicKey,
            challenge: challengeData.base64EncodedString(),
            signature: signature.base64EncodedString()
        )

        let url = URL(string: "\(serverUrl)/v1/auth")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addClientHeaders(to: &urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        try check426(data, response)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            state = .error("Auth failed")
            return
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        if let t = authResponse.token {
            self.token = t
            self.deviceId = authResponse.deviceId
            try keyManager.storeToken(t, forServer: serverUrl)
            Self.logger.info("Authenticated with \(self.serverUrl)")
        } else {
            state = .error("No token received")
        }
    }

    // MARK: - Socket.io Connection

    func connect() {
        guard let token else {
            Self.logger.warning("Cannot connect: no auth token")
            return
        }

        state = .connecting

        let url = URL(string: serverUrl)!
        // Reconnect backoff: was capped at 5s with no jitter. After a network
        // blip every Mac in the field would all hit the server in lockstep
        // every 5s — a small thundering herd. Cap at 30s + use the library's
        // built-in randomization to spread attempts.
        manager = SocketManager(socketURL: url, config: [
            .log(false),
            .path("/v1/updates"),
            .connectParams(["token": token, "clientType": "user-scoped"]),
            .reconnects(true),
            .reconnectWait(2),
            .reconnectWaitMax(30),
            .randomizationFactor(0.5),
            .forceWebsockets(true),
            .extraHeaders([
                "Authorization": "Bearer \(token)",
                "X-Client-Version": Self.clientVersionHeaderValue,
            ]),
        ])

        socket = manager?.defaultSocket

        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                self?.state = .connected
                Self.logger.info("Socket connected to \(self?.serverUrl ?? "")")
            }
        }

        socket?.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                self?.state = .disconnected
                Self.logger.info("Socket disconnected")
            }
        }

        socket?.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in
                let msg = (data.first as? String) ?? "Unknown error"
                self?.state = .error(msg)
                Self.logger.error("Socket error: \(msg)")
            }
        }

        // Handle RPC calls from phone
        socket?.on("rpc-call") { [weak self] data, ack in
            guard let dict = data.first as? [String: Any],
                  let method = dict["method"] as? String,
                  let params = dict["params"] as? String else { return }

            self?.onRpcCall?(method, params) { result in
                ack.with(["ok": true, "result": result] as [String: Any])
            }
        }

        // Handle messages from other devices (phone → terminal)
        socket?.on("update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let type = dict["type"] as? String,
                  type == "new-message",
                  let sessionId = dict["sessionId"] as? String,
                  let msgDict = dict["message"] as? [String: Any],
                  let content = msgDict["content"] as? String else { return }

            // Filter out message types that originate from CodeIsland itself (assistant,
            // tool, thinking, etc.) to avoid echo loops. We keep "user" (plain text from
            // phone) and "key" (control key events from phone). Plain text with no JSON
            // envelope is also treated as user content.
            if let jsonData = content.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let msgType = parsed["type"] as? String {
                let phoneOriginated = Set(["user", "key", "read-screen"])
                if !phoneOriginated.contains(msgType) { return }
            }
            let sessionTag = dict["sessionTag"] as? String
            let sessionPath = dict["sessionPath"] as? String

            // Plain text = message from phone (not JSON-serialized by MessageRelay)
            Task { @MainActor in
                Self.logger.info("Received user message from phone for session \(sessionId.prefix(8))...")
                self?.onUserMessage?(sessionId, content, sessionTag, sessionPath)
            }
        }

        // iPhone unpaired this Mac → clean up local state
        socket?.on("link-removed") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let sourceDeviceId = dict["sourceDeviceId"] as? String else { return }
            Task { @MainActor in
                Self.logger.info("link-removed from iPhone \(sourceDeviceId.prefix(8), privacy: .public)")
                self?.onLinkRemoved?(sourceDeviceId)
            }
        }

        // iPhone requested a remote session launch → spawn cmux subprocess
        socket?.on("session-launch") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let presetId = dict["presetId"] as? String,
                  let projectPath = dict["projectPath"] as? String,
                  let requestedBy = dict["requestedByDeviceId"] as? String else { return }
            Task { @MainActor in
                Self.logger.info("session-launch from iPhone \(requestedBy.prefix(8), privacy: .public): preset=\(presetId, privacy: .public) path=\(projectPath, privacy: .public)")
                self?.onSessionLaunch?(presetId, projectPath, requestedBy)
            }
        }

        // Subscription state changed (redeem, IAP renewal, admin grant).
        // Server F3 routes the event to Mac itself in addition to paired
        // iPhones; without F3 this handler stays silent which is safe.
        // Payload shape: {status, expiresAt?, daysLeft?, source?}
        socket?.on("subscription-updated") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            guard let state = SubscriptionState(serverPayload: dict) else {
                Self.logger.warning("subscription-updated: malformed payload, ignoring")
                return
            }
            Task { @MainActor in
                Self.logger.info("subscription-updated: status=\(state.status.rawValue, privacy: .public) daysLeft=\(state.daysLeft ?? -1)")
                self?.onSubscriptionUpdated?(state)
            }
        }

        socket?.connect()
    }

    func disconnect() {
        socket?.disconnect()
        manager = nil
        socket = nil
        state = .disconnected
    }

    // MARK: - Sending

    /// Send a session message (encrypted content) to the server
    func sendMessage(sessionId: String, content: String, localId: String? = nil) {
        guard isConnected else {
            // OPT-09: dropping upstream messages silently is how "the phone
            // never saw the reply" stays undiagnosable. Leave a file trace.
            DebugLogger.log("Relay", "upstream message dropped (not connected) sid=\(sessionId.prefix(8)) localId=\(localId?.prefix(12).description ?? "-")")
            return
        }

        var payload: [String: Any] = ["sid": sessionId, "message": content]
        if let localId { payload["localId"] = localId }

        socket?.emitWithAck("message", payload).timingOut(after: 30) { data in
            // Socket.IO delivers ["NO ACK"] when the server didn't ack in
            // time (SocketAckStatus.noAck). That's an upstream message the
            // phone will never see — record it instead of ignoring.
            if let status = data.first as? String, status == "NO ACK" {
                DebugLogger.log("Relay", "upstream message ack timeout sid=\(sessionId.prefix(8)) localId=\(localId?.prefix(12).description ?? "-")")
            }
        }
    }

    /// Send session-alive heartbeat
    func sendAlive(sessionId: String) {
        guard isConnected else { return }
        socket?.emit("session-alive", ["sid": sessionId] as [String: Any])
    }

    /// Send session-end
    func sendSessionEnd(sessionId: String) {
        guard isConnected else { return }
        socket?.emit("session-end", ["sid": sessionId] as [String: Any])
    }

    /// Ack successful consumption of a blob so the server can delete it immediately.
    func sendBlobConsumed(blobId: String) {
        guard isConnected else { return }
        socket?.emit("blob-consumed", ["blobId": blobId] as [String: Any])
    }

    /// Push the capability snapshot to the server so the phone can fetch it.
    func uploadCapabilities(_ snapshot: CapabilitySnapshot) async {
        guard let token else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        var request = URLRequest(url: URL(string: "\(serverUrl)/v1/capabilities")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addClientHeaders(to: &request)
        request.httpBody = data
        guard let (respData, resp) = try? await URLSession.shared.data(for: request) else { return }
        try? check426(respData, resp)
    }

    /// Download a blob by ID. Returns (data, mime) or throws.
    func downloadBlob(blobId: String) async throws -> (Data, String) {
        guard let token else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "\(serverUrl)/v1/blobs/\(blobId)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        addClientHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check426(data, response)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "CodeIsland.Blob", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Blob download failed"])
        }
        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg").split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "image/jpeg"
        return (data, mime)
    }

    /// Update session metadata
    func updateMetadata(sessionId: String, metadata: String, expectedVersion: Int) {
        guard isConnected else { return }
        socket?.emitWithAck("update-metadata", [
            "sid": sessionId,
            "metadata": metadata,
            "expectedVersion": expectedVersion,
        ] as [String: Any]).timingOut(after: 10) { _ in }
    }

    /// Register as RPC handler for a method
    func registerRpc(method: String) {
        guard isConnected else { return }
        socket?.emit("rpc-register", ["method": method] as [String: Any])
    }

    // MARK: - HTTP API

    /// Create or load a session on the server
    func createSession(tag: String, metadata: String) async throws -> [String: Any] {
        return try await postJSON(path: "/v1/sessions", body: ["tag": tag, "metadata": metadata])
    }

    // MARK: - HTTP Helpers

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        addClientHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try check426(data, response)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func putJSON(path: String, body: [String: Any]) async throws {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        addClientHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check426(data, response)
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        addClientHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check426(data, response)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func deleteRequest(path: String) async throws {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        addClientHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check426(data, response)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Multi-device pairing API

    /// Register this Mac with the server. Lazy-allocates and returns a permanent shortCode.
    /// Idempotent — call on every launch.
    func registerDevice(name: String, kind: String) async {
        do {
            let res = try await postJSON(path: "/v1/devices/me", body: ["name": name, "kind": kind])
            if let code = res["shortCode"] as? String {
                self.shortCode = code
                Self.logger.info("Registered as \(kind) '\(name)', shortCode=\(code, privacy: .public)")
            } else {
                Self.logger.warning("Device registered but no shortCode returned (kind=\(kind, privacy: .public))")
            }
        } catch {
            Self.logger.error("registerDevice failed: \(error.localizedDescription)")
        }
    }

    /// Upload this Mac's launch presets (full replace).
    func uploadPresets(_ presets: [[String: Any]]) async {
        do {
            try await putJSON(path: "/v1/devices/me/presets", body: ["presets": presets])
        } catch {
            Self.logger.error("uploadPresets failed: \(error.localizedDescription)")
        }
    }

    /// Upload this Mac's known project paths.
    func uploadProjects(_ projects: [[String: String]]) async {
        do {
            try await putJSON(path: "/v1/devices/me/projects", body: ["projects": projects])
        } catch {
            Self.logger.error("uploadProjects failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Linked devices management

    /// A device linked to this Mac (typically an iPhone).
    struct LinkedDeviceInfo: Identifiable {
        let id: String       // deviceId
        let name: String
        let kind: String     // "iphone", "mac"
        let createdAt: String
    }

    /// Fetch all devices linked to this Mac.
    func fetchLinkedDevices() async -> [LinkedDeviceInfo] {
        do {
            let url = URL(string: "\(serverUrl)/v1/pairing/links")!
            var request = URLRequest(url: url)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            addClientHeaders(to: &request)
            let (data, response) = try await URLSession.shared.data(for: request)
            try check426(data, response)
            guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return array.compactMap { dict in
                guard let id = dict["deviceId"] as? String,
                      let name = dict["name"] as? String else { return nil }
                let kind = dict["kind"] as? String ?? "unknown"
                let createdAt = dict["createdAt"] as? String ?? ""
                return LinkedDeviceInfo(id: id, name: name, kind: kind, createdAt: createdAt)
            }
        } catch {
            Self.logger.error("fetchLinkedDevices failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Unlink a paired device. Server cascade-deletes push tokens if no links remain.
    func unlinkDevice(_ deviceId: String) async throws {
        try await deleteRequest(path: "/v1/pairing/links/\(deviceId)")
        Self.logger.info("Unlinked device \(deviceId)")
    }

    // MARK: - Redeem code (trial activation)

    /// Activate a trial code on this Mac. The Mac becomes the redemption
    /// point (Apple Guideline 3.1.1 forced this off iOS); paired iPhones
    /// inherit the trial via DeviceLink + the server's
    /// `subscription-updated` socket event.
    ///
    /// Server contract:
    ///   - 200: { "success": true, "durationDays": N, "expiresAt": ISO8601 }
    ///   - 4xx: { "error": "<machine-key>", "message": "<human>" }
    ///
    /// The HTTP status is intentionally ignored — we branch on `body.error`
    /// since the server may collapse all errors to 400 while keeping the
    /// shape stable. Falls back to `.serverError` on unknown error keys.
    func redeemPairingCode(_ code: String) async throws -> RedemptionRecord {
        guard let token, !token.isEmpty else {
            throw RedeemError.unauthorized
        }
        // Defensive: the serverUrl is validated on input by isValidDraft
        // in PairPhoneView, but a force-unwrap here would crash the app
        // on any malformed config that slipped through. Map to .network
        // so the user gets the directional "check your connection" hint.
        guard let url = URL(string: "\(serverUrl)/v1/pairing/redeem-code") else {
            Self.logger.error("redeemPairingCode: malformed serverUrl=\(self.serverUrl, privacy: .public)")
            throw RedeemError.network
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        addClientHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Self.logger.error("redeemPairingCode network error: \(error.localizedDescription)")
            throw RedeemError.network
        }

        try check426(data, response)

        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

        if (body["success"] as? Bool) == true,
           let durationDays = body["durationDays"] as? Int,
           let expiresAtRaw = body["expiresAt"] as? String,
           let expiresAt = Self.parseISO8601(expiresAtRaw) {
            Self.logger.info("Redeem ok: \(durationDays)d, expires \(expiresAtRaw, privacy: .public)")
            return RedemptionRecord(
                code: code,
                durationDays: durationDays,
                redeemedAt: Date(),
                expiresAt: expiresAt
            )
        }

        if let errorKey = body["error"] as? String {
            let mapped = RedeemError(serverErrorKey: errorKey)
            Self.logger.warning("Redeem failed: \(errorKey, privacy: .public)")
            throw mapped
        }

        Self.logger.error("Redeem response malformed: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>", privacy: .public)")
        throw RedeemError.malformedResponse
    }

    // MARK: - Subscription state (read-only fetch)

    /// Fetch current subscription state for THIS device from the server.
    /// Endpoint: GET /v1/subscription/status (existing — also used by
    /// iPhone via AppState.refreshSubscriptionStatus). Returns nil when
    /// the response can't parse — caller should keep its previous state
    /// rather than wiping the banner on a transient malformation.
    ///
    /// Pre-server-F4: Mac calling this gets short-circuited to
    /// {status:'none', reason:'mac_device'} because checkAccess returns
    /// early on Mac. SyncManager handles that gracefully by keeping any
    /// recent local lastRedemption visible.
    /// Post-F4: server includes Mac's own trialExpiresAt in the response.
    func fetchSubscription() async throws -> SubscriptionState? {
        guard let token, !token.isEmpty else {
            throw RedeemError.unauthorized
        }
        guard let url = URL(string: "\(serverUrl)/v1/subscription/status") else {
            throw RedeemError.network
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        addClientHeaders(to: &request)
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Self.logger.error("fetchSubscription network error: \(error.localizedDescription)")
            throw RedeemError.network
        }

        try check426(data, response)

        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Self.logger.warning("fetchSubscription: non-JSON response, ignoring")
            return nil
        }
        let state = SubscriptionState(serverPayload: body)
        if state == nil {
            Self.logger.warning("fetchSubscription: unrecognised payload \(String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>", privacy: .public)")
        } else {
            Self.logger.info("fetchSubscription ok: status=\(state!.status.rawValue, privacy: .public) daysLeft=\(state!.daysLeft ?? -1)")
        }
        return state
    }

    /// Try ISO8601 with fractional seconds first (`.withFractionalSeconds`
    /// accepts ANY milliseconds value, e.g. `.000Z`, `.514Z`, `.999Z` —
    /// not just `.000`). Falls back to plain (no fractional) for
    /// forward-compat if the server ever drops the fractional part.
    private static func parseISO8601(_ raw: String) -> Date? {
        if let d = iso8601Fractional.date(from: raw) { return d }
        return iso8601Plain.date(from: raw)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
