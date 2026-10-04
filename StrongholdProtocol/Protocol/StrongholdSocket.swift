import Foundation

/// Connection state of the underlying WebSocket.
enum SocketState: Equatable {
    case idle
    case connecting
    case connected
    case closed(reason: String)
}

/// Raw WebSocket transport for the game protocol.
///
/// The web client talks JSON text frames over `ws(s)://<host>/ws`. This class
/// owns one connection, delivers inbound text frames to `onMessage`, and keeps
/// the link alive with the protocol's `ping { c }` keepalive. Reconnection
/// policy lives in the session layer (`GameSession`), not here.
final class StrongholdSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let url: URL
    private let queue: DispatchQueue

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    /// Called on `queue` for every inbound text frame.
    var onMessage: ((String) -> Void)?
    /// Called on `queue` whenever the link opens.
    var onOpen: (() -> Void)?
    /// Called on `queue` when the link closes (with a human-readable reason).
    var onClose: ((String) -> Void)?

    private var pingCounter = 0
    private var pingWorkItem: DispatchWorkItem?

    init(url: URL) {
        self.url = url
        self.queue = DispatchQueue(label: "stronghold.socket", qos: .userInitiated)
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    var state: SocketState {
        if task != nil { return .connected }
        return .idle
    }

    func open() {
        queue.async { [weak self] in
            guard let self, self.task == nil else { return }
            let task = self.session.webSocketTask(with: self.url)
            self.task = task
            task.resume()
            self.receiveLoop()
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pingWorkItem?.cancel()
            self.pingWorkItem = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    func send(text: String, completion: ((Error?) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let task = self.task else {
                completion?(URLError(.notConnectedToInternet))
                return
            }
            task.send(.string(text)) { error in
                completion?(error)
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.onMessage?(text)
                }
                self.queue.async { self.receiveLoop() }
            case .failure(let error):
                self.queue.async {
                    self.pingWorkItem?.cancel()
                    self.pingWorkItem = nil
                    self.task = nil
                    self.onClose?(Self.describe(error))
                }
            }
        }
    }

    /// Sends `ping { c }` every 20 s. The server answers `pong`; the session
    /// layer decides what an unanswered ping means.
    func schedulePing(_ send: @escaping (String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pingWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pingCounter += 1
                let ping = OutgoingMessage.encode(
                    OutgoingMessage.make("ping", ["c": .int(Int64(self.pingCounter))])
                ) ?? "{}"
                send(ping)
                self.schedulePing(send)
            }
            self.pingWorkItem = item
            self.queue.asyncAfter(deadline: .now() + 20, execute: item)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时"
            case .cannotFindHost, .cannotConnectToHost: return "找不到该部署"
            case .networkConnectionLost, .notConnectedToInternet: return "网络连接已断开"
            case .cancelled: return "已取消"
            default: break
            }
        }
        return "连接已断开"
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            self?.onOpen?()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            self?.pingWorkItem?.cancel()
            self?.pingWorkItem = nil
            self?.task = nil
            self?.onClose?("连接已断开")
        }
    }
}
