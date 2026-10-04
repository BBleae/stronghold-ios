import Foundation

/// One saved deployment (the address of a Stronghold Protocol server).
struct Deployment: Identifiable, Equatable, Hashable, Codable {
    var id: UUID
    /// Base URL as entered, e.g. `https://stronghold.lunar.ag` or `http://192.168.1.10:3000`.
    var baseURL: String
    /// Optional label shown in the list; empty means "use the host".
    var label: String
    var createdAt: Date
    var lastUsedAt: Date?

    var displayLabel: String {
        label.isEmpty ? Self.host(of: baseURL) : label
    }

    /// Normalizes user input to a base URL string (scheme + host + optional port, no trailing slash).
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            // LAN addresses default to http; web hosts to https.
            text = looksLikeLocalHost(text) ? "http://\(text)" : "https://\(text)"
        }
        guard var url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        if url.path.isEmpty || url.path == "/" {
            return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        // A path prefix is allowed (some deployments sit behind a reverse proxy).
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        if var mutable = components {
            mutable.path = path
            return mutable.string
        }
        return url.absoluteString
    }

    static func looksLikeLocalHost(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map(String.init) ?? text
        if host == "localhost" { return true }
        // Private ranges and bare IPv4 addresses are reachable over plain http.
        if host.contains(":") { // host:port or IPv6
            let parts = host.split(separator: ":")
            if let first = parts.first, first.split(separator: ".").count == 4 {
                let lead = first.split(separator: ".").compactMap { Int($0) }
                if lead.first == 10 || lead.first == 192 && lead.count > 1 && lead[1] == 168 { return true }
            }
            return false
        }
        if host.split(separator: ".").count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        return false
    }

    static func host(of baseURL: String) -> String {
        URL(string: baseURL)?.host ?? baseURL
    }

    /// The WebSocket endpoint of this deployment.
    var webSocketURL: URL? {
        var components = URLComponents(string: baseURL)
        let scheme = components?.scheme
        components?.scheme = (scheme == "https") ? "wss" : "ws"
        let existingPath = components?.path ?? ""
        if var mutable = components {
            mutable.path = existingPath + "/ws"
            return mutable.url
        }
        return components?.url
    }

    /// Health check endpoint (`GET /healthz`).
    var healthURL: URL? {
        var components = URLComponents(string: baseURL)
        let existingPath = components?.path ?? ""
        if var mutable = components {
            mutable.path = existingPath + "/healthz"
            return mutable.url
        }
        return components?.url
    }
}

/// Persisted list of deployments, stored locally in the app sandbox.
final class DeploymentStore: ObservableObject {
    @Published private(set) var deployments: [Deployment] = []

    private static let storageKey = "deployments.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Deployment].self, from: data) {
            deployments = saved
        }
    }

    func upsert(_ deployment: Deployment) {
        if let index = deployments.firstIndex(where: { $0.id == deployment.id }) {
            deployments[index] = deployment
        } else {
            deployments.append(deployment)
        }
        save()
    }

    func remove(_ deployment: Deployment) {
        deployments.removeAll { $0.id == deployment.id }
        save()
    }

    func markUsed(_ deployment: Deployment) {
        var updated = deployment
        updated.lastUsedAt = Date()
        upsert(updated)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(deployments) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
