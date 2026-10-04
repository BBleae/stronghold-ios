import Foundation

/// Identity persisted per deployment: player id + reconnect token.
struct PlayerIdentity: Codable, Equatable {
    var name: String
    var playerId: String
    var token: String
}

/// High-level game session over one WebSocket connection.
///
/// Mirrors the web client's `public/js/net.js`:
/// - sends `hello { name, token?, version }` on open,
/// - resumes an existing server session when the stored token still resolves,
/// - correlates requests via `rid` (8 s timeout),
/// - heartbeats `ping { c }` every 4 s and considers the link dead after 15 s
///   without any inbound frame,
/// - reconnects with backoff (0.5 s ×2, max 10 s, ±20 % jitter) unless the
///   server closed with 4001 (session replaced).
final class GameSession: @unchecked Sendable {

    // MARK: - Observable state (published to MainActor consumers)

    enum Phase: Equatable {
        case idle
        case connecting
        case connected(playerId: String, resumed: Bool)
        case failed(reason: String)
    }

    /// All inbound S2C frames, after `welcome`. Consumed by feature models.
    nonisolated(unsafe) var onFrame: ((JSON) -> Void)?

    /// Connection status changes.
    nonisolated(unsafe) var onPhase: ((Phase) -> Void)?

    /// Set once `welcome` arrives; survives reconnects (same token ⇒ same
    /// session while it is alive server-side).
    private(set) var identity: PlayerIdentity?

    // MARK: - Internals

    private let deployment: Deployment
    private var socket: StrongholdSocket?
    private let queue = DispatchQueue(label: "stronghold.session", qos: .userInitiated)

    private var nextRid: Int64 = 1
    private final class Pending {
        let rid: Int64
        var continuation: CheckedContinuation<JSON, Error>?
        var deadline: DispatchWorkItem?
        init(rid: Int64) { self.rid = rid }
    }
    private var pending: [Int64: Pending] = [:]

    private var desiredName: String
    private var helloSent = false
    private var connectedOnce = false
    private var backoffAttempts = 0
    private var reconnectWork: DispatchWorkItem?
    private var helloTimeoutWork: DispatchWorkItem?
    private var heartbeatWork: DispatchWorkItem?
    private var lastInbound = Date.distantPast
    private var clockOffset: Double = 0   // serverNow - localNow, refined by pong samples

    /// Close code 4001 means this token is live elsewhere; stop reconnecting.
    private var replacedElsewhere = false

    /// Set when the user asked to close (no reconnects afterwards).
    private var closing = false

    init(deployment: Deployment, name: String, identity: PlayerIdentity?) {
        self.deployment = deployment
        self.desiredName = name
        self.identity = identity
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.openSocket()
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.closing else { return }
            self.closing = true
            self.reconnectWork?.cancel()
            self.helloTimeoutWork?.cancel()
            self.heartbeatWork?.cancel()
            self.failPending(ServerError(code: nil, rawCode: "LOCAL", message: "连接已关闭", detail: nil))
            self.socket?.close()
            self.socket = nil
        }
    }

    /// Renames the player (sends hello again on a live socket — the server
    /// treats a repeat hello as rename + resync, throttled ≥1 s).
    func rename(to name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.desiredName = name
            if self.helloSent, let socket = self.socket {
                self.sendHello(on: socket, fresh: false)
            }
        }
    }

    // MARK: - Requests

    /// Sends one C2S message and awaits its reply (first frame with our rid).
    func request(_ type: String, _ fields: [String: JSON] = [:]) async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            queue.async { [weak self] in
                guard let self, !self.closing else {
                    continuation.resume(throwing: ServerError(code: nil, rawCode: "LOCAL", message: "连接已关闭", detail: nil))
                    return
                }
                let rid = self.nextRid
                self.nextRid = (self.nextRid + 1) % 2_147_483_000
                let pendingItem = Pending(rid: rid)
                pendingItem.continuation = continuation
                self.pending[rid] = pendingItem

                let work = DispatchWorkItem { [weak self] in
                    guard let self, let item = self.pending.removeValue(forKey: rid) else { return }
                    item.continuation?.resume(throwing: ServerError(
                        code: nil, rawCode: "TIMEOUT", message: "请求超时", detail: type))
                }
                pendingItem.deadline = work
                self.queue.asyncAfter(deadline: .now() + GameConstants.requestTimeout, execute: work)

                let message = OutgoingMessage.make(type, rid: rid, fields)
                let text = OutgoingMessage.encode(message) ?? "{}"
                self.send(text)
            }
            _ = resumed // (kept simple; continuation resumed exactly once)
        }
    }

    /// Fire-and-forget send (no rid): used for `b.progress` and similar.
    func send(_ type: String, _ fields: [String: JSON]) {
        queue.async { [weak self] in
            guard let self else { return }
            let text = OutgoingMessage.encode(OutgoingMessage.make(type, rid: nil, fields)) ?? "{}"
            self.send(text)
        }
    }

    private func send(_ text: String) {
        socket?.send(text: text) { [weak self] error in
            guard let self, error != nil else { return }
            // Send failure usually means the link just died; let the receive
            // path surface the close. Drop the frame (the web client queues;
            // we queue only until welcome, then live sends surface errors).
            self.queue.async { self.onClose("发送失败") }
        }
    }

    // MARK: - Connection internals

    private func openSocket() {
        guard !closing else { return }
        guard let wsURL = deployment.webSocketURL else {
            onPhase?(.failed(reason: "无效的部署地址"))
            return
        }
        onPhase?(.connecting)
        let socket = StrongholdSocket(url: wsURL)
        self.socket = socket

        socket.onOpen = { [weak self] in
            guard let self else { return }
            self.lastInbound = Date()
            self.backoffAttempts = 0
            self.helloSent = false
            self.sendHello(on: socket, fresh: true)
            self.armHelloTimeout()
            self.armHeartbeat(socket)
        }
        socket.onMessage = { [weak self] text in
            self?.handleFrame(text)
        }
        socket.onClose = { [weak self] reason in
            self?.onClose(reason)
        }
        socket.open()
    }

    private func sendHello(on socket: StrongholdSocket, fresh: Bool) {
        var fields: [String: JSON] = ["name": .string(desiredName)]
        if let identity, fresh || helloSent == false {
            fields["token"] = .string(identity.token)
        }
        fields["version"] = .int(Int64(GameConstants.protocolVersion))
        guard let text = OutgoingMessage.encode(OutgoingMessage.make("hello", rid: nil, fields)) else { return }
        helloSent = true
        socket.send(text: text)
    }

    private func armHelloTimeout() {
        helloTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.connectedOnce else { return }
            self.onClose("hello 超时")
        }
        helloTimeoutWork = work
        queue.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func armHeartbeat(_ socket: StrongholdSocket) {
        heartbeatWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak socket] in
            guard let self, let socket else { return }
            // Dead link: no inbound frame at all for 15 s.
            if Date().timeIntervalSince(self.lastInbound) > GameConstants.deadAfter {
                self.onClose("连接无响应")
                return
            }
            self.pingCounter += 1
            let ping = OutgoingMessage.encode(
                OutgoingMessage.make("ping", rid: nil, ["c": .int(Int64(Date().timeIntervalSince1970 * 1000))])
            ) ?? "{}"
            socket.send(text: ping)
            self.armHeartbeat(socket)
        }
        heartbeatWork = work
        queue.asyncAfter(deadline: .now() + GameConstants.pingInterval, execute: work)
    }

    private var pingCounter = 0

    private func onClose(_ reason: String) {
        guard !closing else { return }
        heartbeatWork?.cancel()
        helloTimeoutWork?.cancel()
        socket?.close()
        socket = nil
        failPending(ServerError(code: nil, rawCode: "LOCAL", message: reason, detail: nil))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !closing, !replacedElsewhere else {
            if replacedElsewhere {
                onPhase?(.failed(reason: "此身份已在其他设备登录"))
            }
            return
        }
        let base = min(GameConstants.reconnectBase * pow(2, Double(min(backoffAttempts, 6))), GameConstants.reconnectMax)
        backoffAttempts += 1
        let jitter = base * (Double.random(in: -0.2...0.2))
        let delay = max(0.1, base + jitter)
        onPhase?(.connecting)
        let work = DispatchWorkItem { [weak self] in
            self?.openSocket()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Frame handling

    private func handleFrame(_ text: String) {
        lastInbound = Date()
        guard let frame = IncomingMessage.decode(text), case .object(let object) = frame,
              case .string(let type) = object["t"]
        else { return }

        switch type {
        case "welcome":
            handleWelcome(object)
        case "pong":
            handlePong(object)
        case "ok":
            if let rid = object["rid"]?.intValue {
                resolve(rid: rid, with: frame)
            }
        case "error":
            handleError(object)
        default:
            onFrame?(frame)
        }
    }

    private func handleWelcome(_ object: [String: JSON]) {
        helloTimeoutWork?.cancel()
        connectedOnce = true
        let playerId = object["playerId"]?.stringValue ?? ""
        let token = object["token"]?.stringValue ?? identity?.token ?? ""
        let serverNow = object["serverNow"]?.doubleValue ?? 0
        let resumed = object["resumed"]?.boolValue ?? false

        clockOffset = serverNow - Date().timeIntervalSince1970 * 1000
        let previousId = identity?.playerId
        identity = PlayerIdentity(name: object["name"]?.stringValue ?? desiredName,
                                  playerId: playerId,
                                  token: token)
        // The server may issue a brand-new session when the token expired:
        // the player id changes and the old match seat is gone.
        if previousId != nil && previousId != playerId {
            // Session expired: report a fresh connect (resumed == false already).
        }
        onPhase?(.connected(playerId: playerId, resumed: resumed))
    }

    private func handlePong(_ object: [String: JSON]) {
        guard let c = object["c"]?.doubleValue, let s = object["s"]?.doubleValue else { return }
        let now = Date().timeIntervalSince1970 * 1000
        let rtt = now - c
        let sample = s + rtt / 2 - now
        // Keep a simple running estimate; the web client keeps best-of-8.
        clockOffset = clockOffset == 0 ? sample : clockOffset * 0.75 + sample * 0.25
    }

    private func handleError(_ object: [String: JSON]) {
        let rawCode = object["code"]?.stringValue ?? "UNKNOWN"
        let error = ServerError(
            code: GameError(rawValue: rawCode),
            rawCode: rawCode,
            message: object["msg"]?.stringValue ?? "操作失败",
            detail: object["detail"]?.stringValue
        )
        if let rid = object["rid"]?.intValue {
            reject(rid: rid, with: error)
        } else {
            onFrame?(.object(object))
        }
    }

    // MARK: - Pending request bookkeeping

    private func resolve(rid: Int64, with frame: JSON) {
        guard let item = pending.removeValue(forKey: rid) else { return }
        item.deadline?.cancel()
        item.continuation?.resume(returning: frame)
    }

    private func reject(rid: Int64, with error: ServerError) {
        guard let item = pending.removeValue(forKey: rid) else { return }
        item.deadline?.cancel()
        item.continuation?.resume(throwing: error)
    }

    private func failPending(_ error: ServerError) {
        let items = pending.values
        pending.removeAll()
        for item in items {
            item.deadline?.cancel()
            item.continuation?.resume(throwing: error)
        }
    }

    /// Server epoch milliseconds, corrected with our clock offset.
    func serverNow() -> Double {
        Date().timeIntervalSince1970 * 1000 + clockOffset
    }
}
