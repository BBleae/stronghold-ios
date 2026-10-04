import SwiftUI

@main
struct StrongholdProtocol: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // App 固定使用深色主题（design.md §2：界面深绿黑暗色）。
                .preferredColorScheme(.dark)
                // 全局主题色 = 薄荷绿 accent/mint。
                .tint(Theme.mint)
                .onOpenURL { url in
                    Self.handleDeepLink(url)
                }
        }
    }

    /// stronghold://add?url=<deployment-url>&label=<optional label>
    /// Registers a deployment without typing it by hand (e.g. from a website link).
    @MainActor
    static func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "stronghold",
              url.host?.lowercased() == "add" else { return }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        let raw = items.first(where: { $0.name == "url" })?.value ?? ""
        let label = items.first(where: { $0.name == "label" })?.value ?? ""
        guard let normalized = Deployment.normalize(raw) else { return }
        if let existing = DeploymentStore.shared.deployments.first(where: { $0.baseURL == normalized }) {
            var updated = existing
            if !label.isEmpty { updated.label = label }
            DeploymentStore.shared.upsert(updated)
        } else {
            DeploymentStore.shared.upsert(
                Deployment(id: UUID(), baseURL: normalized, label: label, createdAt: Date(), lastUsedAt: nil)
            )
        }
    }
}
