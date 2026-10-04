import SwiftUI

/// 屏 1：连接 — the deployment list and connection management.
struct ConnectionsView: View {
    @StateObject private var store = DeploymentStore()
    @State private var showingAdd = false
    @State private var editing: Deployment?
    @State private var connecting: Deployment?
    @State private var healthMessage: String?
    @State private var path: [LobbyRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.deployments.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("连接")
            .toolbar {
                Button {
                    showingAdd = true
                } label: {
                    Label("添加部署", systemImage: "plus")
                }
                .accessibilityIdentifier("add-deployment")
            }
            .sheet(isPresented: $showingAdd) {
                DeploymentFormSheet(store: store, deployment: nil)
            }
            .sheet(item: $editing) { deployment in
                DeploymentFormSheet(store: store, deployment: deployment)
            }
            .navigationDestination(for: LobbyRoute.self) { route in
                switch route {
                case .lobby(let deployment):
                    LobbyView(deployment: deployment)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有连接任何部署", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("添加一个部署地址，即可开始游玩。")
        } actions: {
            Button("添加部署") { showingAdd = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("add-deployment-empty")
        }
    }

    private var list: some View {
        List {
            if let healthMessage {
                Text(healthMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.deployments) { deployment in
                Button {
                    connect(deployment)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deployment.displayLabel)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(deployment.baseURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connecting?.id == deployment.id {
                            ProgressView()
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.remove(deployment)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        editing = deployment
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.accentColor)
                }
            }
        }
    }

    /// Health-check then enter the lobby (M0: placeholder lobby screen).
    private func connect(_ deployment: Deployment) {
        connecting = deployment
        healthMessage = "检查部署状态…"
        Task {
            let ok = await Self.checkHealth(deployment)
            await MainActor.run {
                connecting = nil
                if ok {
                    healthMessage = nil
                    store.markUsed(deployment)
                    path.append(.lobby(deployment))
                } else {
                    healthMessage = "无法连接该部署。请检查地址和网络。"
                }
            }
        }
    }

    static func checkHealth(_ deployment: Deployment) async -> Bool {
        guard let url = deployment.healthURL else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            // A valid deployment answers /healthz (body content is informational).
            _ = data
            return true
        } catch {
            return false
        }
    }
}

enum LobbyRoute: Hashable {
    case lobby(Deployment)
}

/// 添加部署 / 编辑 — one form for both.
struct DeploymentFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: DeploymentStore

    let deployment: Deployment?
    @State private var baseURL: String = ""
    @State private var label: String = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("输入部署地址（如 https://stronghold.lunar.ag）", text: $baseURL, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .monospaced()
                    .accessibilityIdentifier("deployment-url")
                TextField("备注名（可选）", text: $label)
                    .accessibilityIdentifier("deployment-label")
                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(deployment == nil ? "添加部署" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("save-deployment")
                }
            }
            .onAppear {
                if let deployment {
                    baseURL = deployment.baseURL
                    label = deployment.label
                }
            }
        }
    }

    private func save() {
        guard let normalized = Deployment.normalize(baseURL) else {
            errorText = "无法连接该部署。请检查地址和网络。"
            return
        }
        var updated = deployment ?? Deployment(
            id: UUID(), baseURL: normalized, label: "", createdAt: Date(), lastUsedAt: nil
        )
        updated.baseURL = normalized
        updated.label = label.trimmingCharacters(in: .whitespaces)
        store.upsert(updated)
        dismiss()
    }
}
