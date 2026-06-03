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

    var isConnected: Bool { state == .connected }

    init(serverUrl: String, keyManager: KeyManager = KeyManager(serviceName: "com.codeisland.keys")) {
        self.serverUrl = serverUrl
        self.keyManager = keyManager
        self.token = keyManager.loadToken(forServer: serverUrl)
    }

    // MARK: - Authentication

    func authenticate() async throws {
        state = .authenticating

        // Slock monitoring auth: PREFER the enrollment machine_token. Since Slice 7,
        // POST /v1/auth hard-requires a user_sess_ that this machine-scoped daemon
        // does not have. After workspace enrollment we DO hold a machine_token (in
        // the mio-agent Keychain item), and POST /v1/auth/machine exchanges it for a
        // monitoring device JWT + shortCode — so one QR scan sets up both universes.
        // Fall back to the legacy device-keypair flow only when no machine_token is
        // present (Mac not yet enrolled).
        if let machineToken = Self.readMachineToken() {
            do {
                try await authenticateWithMachineToken(machineToken)
                return
            } catch {
                Self.logger.error("machine_token auth failed: \(error.localizedDescription, privacy: .public) — falling back to keypair")
            }
        }

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
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

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

    /// Read the enrollment machine_token from the mio-agent Keychain item.
    /// mio-agent stores it via `security add-generic-password` with NO app ACL
    /// (`-T`), so the only trusted app is `/usr/bin/security` itself — any
    /// same-user process reading through `security find-generic-password`
    /// succeeds WITHOUT a Keychain prompt. The token never touches logs.
    private static func readMachineToken() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password",
                          "-s", "io.miomioos.mio-agent",
                          "-a", "machine_token",
                          "-w"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let tok = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (tok?.isEmpty == false) ? tok : nil
        } catch {
            return nil
        }
    }

    /// Exchange a machine_token for a monitoring device JWT + shortCode via
    /// POST /v1/auth/machine. On success sets token / deviceId / shortCode and
    /// persists the JWT to the Keychain (same slot the keypair flow uses).
    private func authenticateWithMachineToken(_ machineToken: String) async throws {
        let url = URL(string: "\(serverUrl)/v1/auth/machine")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(machineToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ServerConnection", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no http response"])
        }
        guard http.statusCode == 200 else {
            throw NSError(domain: "ServerConnection", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "machine auth http \(http.statusCode)"])
        }

        struct MachineAuthResponse: Decodable {
            let token: String?
            let deviceId: String?
            let shortCode: String?
        }
        let parsed = try JSONDecoder().decode(MachineAuthResponse.self, from: data)
        guard let t = parsed.token else {
            throw NSError(domain: "ServerConnection", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "machine auth returned no token"])
        }
        self.token = t
        self.deviceId = parsed.deviceId
        if let sc = parsed.shortCode { self.shortCode = sc }
        try keyManager.storeToken(t, forServer: serverUrl)
        Self.logger.info("Authenticated via machine_token with \(self.serverUrl), shortCode=\(self.shortCode ?? "nil", privacy: .public)")
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
            .extraHeaders(["Authorization": "Bearer \(token)"]),
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
        guard isConnected else { return }

        var payload: [String: Any] = ["sid": sessionId, "message": content]
        if let localId { payload["localId"] = localId }

        socket?.emitWithAck("message", payload).timingOut(after: 30) { _ in }
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
        request.httpBody = data
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Download a blob by ID. Returns (data, mime) or throws.
    func downloadBlob(blobId: String) async throws -> (Data, String) {
        guard let token else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: URL(string: "\(serverUrl)/v1/blobs/\(blobId)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func putJSON(path: String, body: [String: Any]) async throws {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func deleteRequest(path: String) async throws {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await URLSession.shared.data(for: request)
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
            let (data, _) = try await URLSession.shared.data(for: request)
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
}
