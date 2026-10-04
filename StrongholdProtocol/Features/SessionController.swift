import Foundation
import Combine

/// Player identity persisted per deployment (hello token ⇒ reconnect).
/// Stored locally only; the deployment owns the real account of record.
final class IdentityStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for deployment: Deployment) -> String {
        "identity.\(deployment.baseURL)"
    }

    func identity(for deployment: Deployment) -> PlayerIdentity? {
        guard let data = defaults.data(forKey: key(for: deployment)) else { return nil }
        return try? JSONDecoder().decode(PlayerIdentity.self, from: data)
    }

    func save(_ identity: PlayerIdentity, for deployment: Deployment) {
        if let data = try? JSONEncoder().encode(identity) {
            defaults.set(data, forKey: key(for: deployment))
        }
    }

    /// The nickname the player last used anywhere (prefill for hello).
    var lastName: String {
        get { defaults.string(forKey: "player.lastName") ?? "" }
        set { defaults.set(newValue, forKey: "player.lastName") }
    }
}

/// Bridges a GameSession to SwiftUI: publishes phase, room state, toasts.
@MainActor
final class SessionController: ObservableObject {
    enum ConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published var phase: ConnectionPhase = .idle
    @Published var roomState: JSON?
    @Published var toast: String?
    /// True once the session has reached `connected` at least once this run;
    /// a `.connecting` phase after that means an in-place reconnect.
    @Published private(set) var hasConnected = false

    var isReconnecting: Bool {
        hasConnected && phase == .connecting
    }

    let deployment: Deployment
    private let store = IdentityStore()
    private var session: GameSession?

    var identity: PlayerIdentity? { session?.identity ?? store.identity(for: deployment) }
    var playerId: String? { identity?.playerId }

    init(deployment: Deployment) {
        self.deployment = deployment
    }

    /// Connects (or resumes) with the given nickname.
    func start(name: String) {
        guard session == nil else { return }
        store.lastName = name
        let session = GameSession(deployment: deployment,
                                  name: name,
                                  identity: store.identity(for: deployment))
        self.session = session
        session.onPhase = { [weak self] phase in
            Task { @MainActor in
                guard let self else { return }
                switch phase {
                case .idle:
                    self.phase = .idle
                case .connecting:
                    self.phase = .connecting
                case .connected(_, let resumed):
                    self.phase = .connected
                    self.hasConnected = true
                    if let identity = self.session?.identity {
                        self.store.save(identity, for: self.deployment)
                    }
                    if resumed {
                        self.toast = "已重新连接"
                    }
                case .failed(let reason):
                    self.phase = .failed(reason)
                }
            }
        }
        session.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.handleFrame(frame)
            }
        }
        phase = .connecting
        session.start()
    }

    func shutdown() {
        session?.close()
        session = nil
        phase = .idle
        roomState = nil
        hasConnected = false
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    // MARK: - Intents

    func createRoom(mode: String, difficulty: GameDifficulty) {
        Task {
            _ = try? await session?.request("room.create", [
                "mode": .string(mode),
                "difficulty": .string(difficulty.rawValue),
            ])
        }
    }

    func joinRoom(code: String) {
        Task {
            _ = try? await session?.request("room.join", ["code": .string(code.uppercased())])
        }
    }

    func setReady(_ ready: Bool) {
        Task {
            _ = try? await session?.request("room.ready", ["ready": .bool(ready)])
        }
    }

    func setDifficulty(_ difficulty: GameDifficulty) {
        Task {
            _ = try? await session?.request("room.setDifficulty", ["difficulty": .string(difficulty.rawValue)])
        }
    }

    func addBot() {
        Task { _ = try? await session?.request("room.addBot") }
    }

    func removeBot(seat: Int) {
        Task { _ = try? await session?.request("room.removeBot", ["seat": .int(Int64(seat))]) }
    }

    func startMatch() {
        Task { _ = try? await session?.request("room.start") }
    }

    func leaveRoom() {
        Task { _ = try? await session?.request("room.leave") }
    }

    func infoReady() {
        Task { _ = try? await session?.request("g.infoReady") }
    }

    // MARK: - Inbound

    private func handleFrame(_ frame: JSON) {
        guard case .object(let object) = frame, case .string(let type) = object["t"] else { return }
        switch type {
        case "room.state":
            roomState = frame
        case "room.closed":
            roomState = nil
            toast = "房间已关闭"
        case "m.toast":
            toast = object["text"]?.stringValue
        default:
            break
        }
    }
}
