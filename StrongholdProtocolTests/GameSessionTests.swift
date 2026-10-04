import XCTest
import Network
@testable import StrongholdProtocol

/// A minimal in-process WebSocket server that speaks enough of the game
/// protocol to exercise the session layer end to end: hello → welcome,
/// room.create → ok + room.state. Frames are JSON text, like the real server.
final class LoopbackGameServer: @unchecked Sendable {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Responds to one inbound text frame; return nil to stay silent.
    var handle: (@Sendable (String, Connection) -> String?)?

    final class Connection: @unchecked Sendable {
        let connection: NWConnection
        init(connection: NWConnection) { self.connection = connection }

        func send(_ text: String) {
            let context = NWConnection.ContentContext.defineWebSocket(text: text)
            connection.send(content: text.data(using: .utf8)!, contentContext: context,
                            completion: .contentProcessed { _ in })
        }
    }

    private var connections: [ObjectIdentifier: Connection] = [:]
    private let lock = NSLock()

    var readyContinuation: CheckedContinuation<Void, Never>?

    func start() async throws {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = listener.port?.rawValue ?? 0
                    self?.readyContinuation?.resume()
                    self?.readyContinuation = nil
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let conn = Connection(connection: connection)
                self.lock.lock()
                self.connections[ObjectIdentifier(connection)] = conn
                self.lock.unlock()
                connection.stateUpdateHandler = { state in
                    if case .failed = state {
                        self.lock.lock()
                        self.connections.removeValue(forKey: ObjectIdentifier(connection))
                        self.lock.unlock()
                    }
                }
                connection.start(queue: .global())
                self.receive(on: conn)
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener?.cancel()
        lock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for conn in all { conn.connection.cancel() }
    }

    private func receive(on conn: Connection) {
        conn.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error == nil {
                if let data, let text = String(data: data, encoding: .utf8),
                   context?.isWebSocketText == true {
                    if let reply = self.handle?(text, conn) {
                        conn.send(reply)
                    }
                }
                self.receive(on: conn)
            } else {
                self.lock.lock()
                self.connections.removeValue(forKey: ObjectIdentifier(conn.connection))
                self.lock.unlock()
            }
        }
    }
}

extension NWConnection.ContentContext {
    /// A text-frame WebSocket content context.
    static func defineWebSocket(text: String) -> NWConnection.ContentContext {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        return NWConnection.ContentContext(identifier: "text", metadata: [metadata])
    }
}

extension NWConnection.ContentContext {
    var isWebSocketText: Bool {
        if let metadata = self.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata {
            return metadata.opcode == .text
        }
        return false
    }
}

final class GameSessionTests: XCTestCase {

    func testHelloWelcomeAndRoomCreate() async throws {
        let server = LoopbackGameServer()
        try await server.start()
        defer { server.stop() }

        server.handle = { text, conn in
            guard let frame = IncomingMessage.decode(text), case .object(let obj) = frame,
                  case .string(let t) = obj["t"] else { return nil }
            switch t {
            case "hello":
                return OutgoingMessage.encode(.object([
                    "t": .string("welcome"),
                    "playerId": .string("p_abcdef1234"),
                    "token": .string("0123456789abcdef0123456789abcdef"),
                    "name": .string(obj["name"]?.stringValue ?? ""),
                    "serverNow": .int(1_700_000_000_000),
                    "version": .int(1),
                    "resumed": .bool(false),
                ]))
            case "room.create":
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    conn.send(OutgoingMessage.encode(.object(["t": .string("ok"), "rid": obj["rid"] ?? .null])) ?? "{}")
                    conn.send(OutgoingMessage.encode(.object([
                        "t": .string("room.state"),
                        "code": .string("ABCD"),
                        "hostId": .string("p_abcdef1234"),
                        "mode": .string(obj["mode"]?.stringValue ?? "solo"),
                        "difficulty": .string(obj["difficulty"]?.stringValue ?? "NORMAL"),
                        "inMatch": .bool(false),
                        "seats": .array([]),
                    ])) ?? "{}")
                }
                return nil
            default:
                return OutgoingMessage.encode(.object(["t": .string("ok"), "rid": obj["rid"] ?? .null]))
            }
        }

        let deployment = Deployment(id: UUID(), baseURL: "http://127.0.0.1:\(server.port)",
                                    label: "", createdAt: Date(), lastUsedAt: nil)
        let session = GameSession(deployment: deployment, name: "Qingmao", identity: nil)
        defer { session.close() }

        let welcome = expectation(description: "welcome")
        session.onPhase = { phase in
            if case .connected = phase { welcome.fulfill() }
        }

        session.start()
        await fulfillment(of: [welcome], timeout: 5)
        XCTAssertEqual(session.identity?.playerId, "p_abcdef1234")
        XCTAssertNotNil(session.identity?.token)

        // room.create round-trips through rid correlation.
        let reply = try await session.request("room.create", [
            "mode": .string("solo"), "difficulty": .string("NORMAL"),
        ])
        XCTAssertEqual(reply["t"]?.stringValue, "ok")

        // A server error frame surfaces as a thrown ServerError.
        server.handle = { text, _ in
            guard let frame = IncomingMessage.decode(text), case .object(let obj) = frame,
                  case .string(let t) = obj["t"] else { return nil }
            return OutgoingMessage.encode(.object([
                "t": .string("error"), "code": .string("ROOM_FULL"),
                "msg": .string("房间已满"), "rid": obj["rid"] ?? .null,
            ]))
        }
        do {
            _ = try await session.request("room.join", ["code": .string("ZZZZ")])
            XCTFail("expected error")
        } catch let error as ServerError {
            XCTAssertEqual(error.code, .roomFull)
        }
    }

    func testJSONRoundTrip() throws {
        let original: JSON = .object([
            "t": .string("m.private"),
            "funds": .int(42),
            "ratio": .double(0.5),
            "flag": .bool(true),
            "list": .array([.int(1), .string("a")]),
            "nested": .object(["k": .string("v")]),
        ])
        let text = OutgoingMessage.encode(original)!
        let back = IncomingMessage.decode(text)
        XCTAssertEqual(back, original)
    }
}
