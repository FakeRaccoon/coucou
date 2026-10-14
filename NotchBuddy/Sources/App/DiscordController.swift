import Foundation
import AppKit

// MARK: - Models

struct DiscordVoiceUser: Identifiable, Equatable {
    let id: String
    var username: String
    var avatar: String?      // avatar hash → CDN URL
    var mute: Bool
    var deaf: Bool
    var speaking: Bool
}

struct DiscordNotification: Identifiable, Equatable {
    let id: String
    var title: String
    var body: String
    var date: Date
}

enum DiscordStatus: Equatable {
    case idle
    case connecting
    case awaitingConsent
    case connected
    case error(String)
}

// MARK: - DiscordController
// Talks to the local Discord desktop app over its IPC socket (same transport
// Overlayed uses). Discord requires OAuth for voice data: the user brings their
// own Discord application (client id + secret in the Keychain), taps Connect,
// approves Discord's consent dialog, and the code-for-token exchange happens
// directly against discord.com/api/oauth2/token. No bot, no third-party server.
//
// Opcodes: client → 0 handshake / 1 command; server → 0-1 dispatch, 2 ping
// (we echo op 3), 1 close. Voice events (VOICE_STATE_*, SPEAKING_*) subscribe
// per channel; channel/connection/notification events subscribe globally.

final class DiscordController: @unchecked Sendable {
    static let shared = DiscordController()
    static let pillId = "integration_discord"

    private let io = DispatchQueue(label: "coucou.discord.ipc")
    private var sockFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var inbound = Data()
    private var reconnectTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    private var lastFrameAt = Date.distantPast
    private var generation = 0

    private var pending: [String: ([String: Any]) -> Void] = [:]
    private var speakingResets: [String: DispatchWorkItem] = [:]
    private var connectedToSocket = false
    private var readyReceived = false
    private var authenticated = false
    private var wantsAuthorize = false
    private var subscribedChannelId: String?
    private var selfId: String?
    private var backoffSeconds = 3

    private init() {}

    // MARK: - Settings

    var clientId: String {
        let stored = KeychainStore.shared.get("discord-client-id") ?? ""
        return stored.isEmpty ? "905987126099836938" : stored   // public fallback (Overlayed's app id): enough for READY
    }
    private var clientSecret: String { KeychainStore.shared.get("discord-client-secret") ?? "" }
    private var redirectURI: String {
        let stored = KeychainStore.shared.get("discord-redirect-uri") ?? ""
        return stored.isEmpty ? "http://localhost" : stored
    }
    private var accessToken: String { KeychainStore.shared.get("discord-access-token") ?? "" }
    private var refreshToken: String { KeychainStore.shared.get("discord-refresh-token") ?? "" }
    private static let scopes = ["identify", "rpc", "rpc.notifications.read"]

    var isDiscordInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.hnc.Discord") != nil
    }

    // MARK: - Lifecycle

    func start() {
        io.async { [weak self] in
            guard let self, self.sockFD == -1 else { return }
            self.connect()
            self.watchdogTimer?.cancel()
            let wd = DispatchSource.makeTimerSource(queue: self.io)
            wd.schedule(deadline: .now() + 15, repeating: 15)
            wd.setEventHandler { [weak self] in
                guard let self else { return }
                // Discord pings regularly; silence past 30s means a dead socket.
                if self.connectedToSocket && Date().timeIntervalSince(self.lastFrameAt) > 30 {
                    self.teardown(reason: "watchdog")
                }
            }
            wd.resume()
            self.watchdogTimer = wd
        }
    }

    func disconnect() {
        io.async { [weak self] in
            guard let self else { return }
            self.teardown(reason: "user")
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
        }
    }

    func settingsChanged() {
        // New credentials: drop everything and reconnect from a clean slate.
        io.async { [weak self] in
            guard let self else { return }
            self.teardown(reason: "settings")
            self.backoffSeconds = 3
            self.connect()
        }
    }

    // MARK: - Socket

    private func socketPath() -> String? {
        var candidates: [String] = []
        let dirs: [String] = [
            ProcessInfo.processInfo.environment["TMPDIR"] ?? "",
            "/tmp", NSTemporaryDirectory(),
            ("~/Library/Application Support/discord" as NSString).expandingTildeInPath,
            ("~/Library/Application Support/discordcanary" as NSString).expandingTildeInPath,
            ("~/Library/Application Support/discordptb" as NSString).expandingTildeInPath,
        ]
        for dir in dirs where !dir.isEmpty {
            for n in 0..<10 { candidates.append("\(dir)/discord-ipc-\(n)") }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func connect() {
        guard sockFD == -1 else { return }
        guard let path = socketPath() else {
            scheduleReconnect(); return
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { scheduleReconnect(); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); scheduleReconnect(); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { close(fd); scheduleReconnect(); return }

        sockFD = fd
        connectedToSocket = true
        lastFrameAt = Date()
        backoffSeconds = 3
        inbound = Data()
        generation += 1
        authenticated = false

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        src.setEventHandler { [weak self] in self?.pumpRead() }
        src.setCancelHandler { [weak self] in
            guard let self, self.sockFD != -1 else { return }
            Darwin.close(self.sockFD)
            self.sockFD = -1
        }
        src.resume()
        readSource = src

        send(op: 0, payload: ["v": 1, "client_id": clientId])
        setStatus(.connecting)
    }

    private func scheduleReconnect() {
        reconnectTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: io)
        t.schedule(deadline: .now() + .seconds(backoffSeconds))
        backoffSeconds = min(backoffSeconds * 2, 30)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            t.cancel()
            self.reconnectTimer = nil
            self.connect()
        }
        t.resume()
        reconnectTimer = t
    }

    private func teardown(reason: String) {
        readSource?.cancel()
        readSource = nil
        connectedToSocket = false
        readyReceived = false
        authenticated = false
        subscribedChannelId = nil
        pending.removeAll()
        appendAppLog("discord", "IPC down (\(reason))")
        if reason != "user" {
            setStatus(.connecting)
            scheduleReconnect()
        }
    }

    private func pumpRead() {
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(sockFD, &buf, buf.count)
            if n <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                teardown(reason: "read")
                return
            }
            lastFrameAt = Date()
            inbound.append(contentsOf: buf[0..<n])
            parseInbound()
        }
    }

    private func parseInbound() {
        while inbound.count >= 8 {
            let op = inbound.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
            let len = inbound.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            guard inbound.count >= 8 + Int(len) else { return }
            let body = inbound.subdata(in: 8..<(8 + Int(len)))
            inbound.removeSubrange(0..<(8 + Int(len)))
            let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

            if op == 2 { send(op: 3, payload: payload); continue }   // ping → pong
            handle(payload: payload)
        }
    }

    // MARK: - Send

    private func send(op: UInt32, payload: [String: Any]) {
        guard sockFD != -1, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var header = Data(count: 8)
        header.withUnsafeMutableBytes {
            $0.storeBytes(of: op.littleEndian, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: UInt32(data.count).littleEndian, toByteOffset: 4, as: UInt32.self)
        }
        var out = header
        out.append(data)
        let err = out.withUnsafeBytes { raw in
            Darwin.send(sockFD, raw.baseAddress, raw.count, 0)
        }
        if err < 0 { teardown(reason: "write") }
    }

    private func command(_ cmd: String, args: [String: Any] = [:], nonce: String? = nil,
                         handler: (([String: Any]) -> Void)? = nil) {
        let n = nonce ?? UUID().uuidString
        if let handler { pending[n] = handler }
        var payload: [String: Any] = ["cmd": cmd, "nonce": n]
        if !args.isEmpty { payload["args"] = args }
        send(op: 1, payload: payload)
    }

    // MARK: - Frames from Discord

    private func handle(payload: [String: Any]) {
        let cmd = payload["cmd"] as? String
        let evt = payload["evt"] as? String
        let nonce = payload["nonce"] as? String
        let data = payload["data"] as? [String: Any] ?? [:]

        if let nonce, let handler = pending.removeValue(forKey: nonce) {
            handler(payload)
        }

        switch evt {
        case "READY":
            readyReceived = true
            selfId = (data["user"] as? [String: Any])?["id"] as? String
            // Socket is up: resume an existing session if we still hold a token.
            if !authenticated {
                if !accessToken.isEmpty {
                    command("AUTHENTICATE", args: ["access_token": accessToken])
                } else if wantsAuthorize {
                    sendAuthorize()
                } else {
                    setStatus(.idle)
                }
            }
        case "ERROR":
            let code = (data["code"] as? Int) ?? 0
            let message = (data["message"] as? String) ?? "error"
            if cmd == "AUTHENTICATE" && code == 4006 {
                if !refreshToken.isEmpty { refreshSession() }
                else { KeychainStore.shared.remove("discord-access-token"); setStatus(.idle) }
            } else if cmd == "AUTHORIZE" {
                setStatus(.error(message))
            }
        default: break
        }

        switch cmd {
        case "AUTHENTICATE":
            if evt != "ERROR", let user = data["user"] as? [String: Any] {
                authenticated = true
                selfId = (user["id"] as? String) ?? selfId
                appendAppLog("discord", "authenticated as \((user["username"] as? String) ?? "?")")
                setStatus(.connected)
                subscribeGlobals()
                command("GET_VOICE_SETTINGS")
                command("GET_SELECTED_VOICE_CHANNEL")
            }
        case "GET_VOICE_SETTINGS":
            if let mute = data["mute"] as? Bool, let deaf = data["deaf"] as? Bool {
                DispatchQueue.main.async {
                    AppState.shared.discordSelfMute = mute
                    AppState.shared.discordSelfDeaf = deaf
                }
            }
        case "GET_SELECTED_VOICE_CHANNEL":
            if evt != "ERROR" { applyChannel(data) }
        default: break
        }

        if cmd == "DISPATCH", let evt {
            handleEvent(evt, data: data)
        }
    }

    private func handleEvent(_ evt: String, data: [String: Any]) {
        switch evt {
        case "VOICE_CHANNEL_SELECT":
            if let channelId = data["channel_id"] as? String, !channelId.isEmpty {
                command("GET_SELECTED_VOICE_CHANNEL")
            } else {
                clearChannel()
            }
        case "VOICE_CONNECTION_STATUS":
            if (data["state"] as? String) == "VOICE_DISCONNECTED" && subscribedChannelId != nil {
                command("GET_SELECTED_VOICE_CHANNEL")
            }
        case "VOICE_SETTINGS_UPDATE":
            if let mute = data["mute"] as? Bool, let deaf = data["deaf"] as? Bool {
                DispatchQueue.main.async {
                    AppState.shared.discordSelfMute = mute
                    AppState.shared.discordSelfDeaf = deaf
                }
            }
        case "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE":
            if let user = voiceUser(from: data) {
                DispatchQueue.main.async {
                    let app = AppState.shared
                    if let i = app.discordUsers.firstIndex(where: { $0.id == user.id }) {
                        app.discordUsers[i] = user
                    } else {
                        app.discordUsers.append(user)
                    }
                }
            }
        case "VOICE_STATE_DELETE":
            guard let user = data["user"] as? [String: Any],
                  let uid = user["id"] as? String else { return }
            if uid == selfId {
                clearChannel()
            } else {
                DispatchQueue.main.async {
                    AppState.shared.discordUsers.removeAll { $0.id == uid }
                }
            }
        case "SPEAKING_START":
            if let uid = data["user_id"] as? String { setSpeaking(uid, true) }
        case "SPEAKING_STOP":
            if let uid = data["user_id"] as? String { setSpeaking(uid, false) }
        case "NOTIFICATION_CREATE":
            let title = (data["title"] as? String) ?? "Discord"
            let body  = (data["body"] as? String) ?? ""
            DispatchQueue.main.async { [weak self] in
                let app = AppState.shared
                let note = DiscordNotification(id: UUID().uuidString, title: title, body: body, date: Date())
                app.discordNotifications.insert(note, at: 0)
                if app.discordNotifications.count > 20 { app.discordNotifications.removeLast() }
                self?.flashBadge()
                SoundEngine.shared.play("finish")
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }
        default: break
        }
    }

    // MARK: - Voice state

    private func voiceUser(from data: [String: Any]) -> DiscordVoiceUser? {
        guard let user = data["user"] as? [String: Any],
              let uid = user["id"] as? String else { return nil }
        let username = (user["username"] as? String)
            ?? ((user["global_name"] as? String) ?? "user")
        let selfMute = data["self_mute"] as? Bool
        let selfDeaf = data["self_deaf"] as? Bool
        let mute = selfMute ?? (data["mute"] as? Bool) ?? false
        let deaf = selfDeaf ?? (data["deaf"] as? Bool) ?? false
        return DiscordVoiceUser(id: uid, username: username,
                                avatar: user["avatar"] as? String,
                                mute: mute, deaf: deaf, speaking: false)
    }

    private func setSpeaking(_ uid: String, _ speaking: Bool) {
        speakingResets.removeValue(forKey: uid)?.cancel()
        DispatchQueue.main.async {
            if let i = AppState.shared.discordUsers.firstIndex(where: { $0.id == uid }) {
                AppState.shared.discordUsers[i].speaking = speaking
            }
        }
        if speaking {
            let work = DispatchWorkItem { [weak self] in self?.setSpeaking(uid, false) }
            io.asyncAfter(deadline: .now() + 4, execute: work)   // STOP lost → self-heal
            speakingResets[uid] = work
        }
        flashEmote(speaking)
    }

    private func applyChannel(_ data: [String: Any]) {
        guard let channelId = data["id"] as? String else { return }
        let name = (data["name"] as? String) ?? "Voice"
        let states = (data["voice_states"] as? [[String: Any]]) ?? []
        let users = states.compactMap { voiceUser(from: $0) }

        if subscribedChannelId != channelId {
            if let old = subscribedChannelId { unsubscribeChannel(old) }
            subscribeChannel(channelId)
        }
        DispatchQueue.main.async {
            let app = AppState.shared
            app.discordChannelName = name
            app.discordUsers = users
        }
    }

    private func clearChannel() {
        if let old = subscribedChannelId { unsubscribeChannel(old) }
        subscribedChannelId = nil
        DispatchQueue.main.async {
            let app = AppState.shared
            app.discordChannelName = ""
            app.discordUsers = []
        }
    }

    private func subscribeGlobals() {
        for evt in ["VOICE_CHANNEL_SELECT", "VOICE_CONNECTION_STATUS", "NOTIFICATION_CREATE"] {
            sendSubscribe(evt: evt, args: [:])
        }
    }

    private func subscribeChannel(_ id: String) {
        subscribedChannelId = id
        for evt in ["SPEAKING_START", "SPEAKING_STOP", "VOICE_STATE_CREATE",
                    "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE"] {
            sendSubscribe(evt: evt, args: ["channel_id": id])
        }
    }

    private func unsubscribeChannel(_ id: String) {
        for evt in ["SPEAKING_START", "SPEAKING_STOP", "VOICE_STATE_CREATE",
                    "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE"] {
            sendSubscribe(evt: evt, args: ["channel_id": id], unsubscribe: true)
        }
    }

    private func sendSubscribe(evt: String, args: [String: Any], unsubscribe: Bool = false) {
        let payload: [String: Any] = ["cmd": unsubscribe ? "UNSUBSCRIBE" : "SUBSCRIBE",
                                      "args": args, "evt": evt, "nonce": UUID().uuidString]
        send(op: 1, payload: payload)
    }

    // MARK: - OAuth

    func authorize() {
        io.async { [weak self] in
            guard let self else { return }
            guard !self.clientSecret.isEmpty else {
                appendAppLog("discord", "authorize refused: client secret empty")
                self.setStatus(.error("Add your Discord client id and secret first")); return
            }
            if self.sockFD == -1 { self.connect() }
            self.setStatus(.awaitingConsent)
            if self.readyReceived { self.sendAuthorize() } else { self.wantsAuthorize = true }
        }
    }

    /// Discord pops its own consent dialog for these scopes; the answer carries
    /// the OAuth code we exchange for tokens.
    private func sendAuthorize() {
        wantsAuthorize = false
        appendAppLog("discord", "AUTHORIZE sent (client \(clientId.prefix(8))…, scopes \(Self.scopes.joined(separator: ",")))")
        command("AUTHORIZE", args: ["client_id": clientId, "scopes": Self.scopes]) { [weak self] payload in
            guard let self else { return }
            if let code = (payload["data"] as? [String: Any])?["code"] as? String {
                self.exchangeCode(code)
            }
        }
    }

    private func exchangeCode(_ code: String) {
        var req = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                appendAppLog("discord", "token exchange FAILED (body: \(data.flatMap { String(data: $0, encoding: .utf8) } ?? "no data"))")
                self?.setStatus(.error("Token exchange failed — check id/secret/redirect URI"))
                return
            }
            appendAppLog("discord", "token exchange OK")
            let refresh = (json["refresh_token"] as? String) ?? ""
            KeychainStore.shared.set("discord-access-token", value: access)
            if !refresh.isEmpty { KeychainStore.shared.set("discord-refresh-token", value: refresh) }
            self.io.async {
                self.authenticated = false
                self.command("AUTHENTICATE", args: ["access_token": access])
            }
        }.resume()
    }

    private func refreshSession() {
        var req = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                KeychainStore.shared.remove("discord-access-token")
                KeychainStore.shared.remove("discord-refresh-token")
                self?.setStatus(.idle)
                return
            }
            KeychainStore.shared.set("discord-access-token", value: access)
            if let refresh = json["refresh_token"] as? String {
                KeychainStore.shared.set("discord-refresh-token", value: refresh)
            }
            self.io.async {
                self.command("AUTHENTICATE", args: ["access_token": access])
            }
        }.resume()
    }

    // MARK: - Pill UI

    private func setStatus(_ s: DiscordStatus) {
        DispatchQueue.main.async { AppState.shared.discordStatus = s }
    }

    @MainActor private func flashBadge() {
        let app = AppState.shared
        guard let idx = app.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        app.tasks[idx].pillBadge = .finished
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }),
                  AppState.shared.tasks[i].pillBadge == .finished else { return }
            AppState.shared.tasks[i].pillBadge = nil
        }
    }

    private func flashEmote(_ active: Bool) {
        guard active else { return }
        DispatchQueue.main.async {
            let app = AppState.shared
            guard let idx = app.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
            app.tasks[idx].emote = .listening
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let i = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }),
                      AppState.shared.tasks[i].emote == .listening else { return }
                AppState.shared.tasks[i].emote = nil
            }
        }
    }

    func openDiscord() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.hnc.Discord") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }
}
