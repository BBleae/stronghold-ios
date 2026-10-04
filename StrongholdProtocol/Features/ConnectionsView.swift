import SwiftUI

/// 屏 1：连接 — the deployment list and connection management.
struct ConnectionsView: View {
    @StateObject private var store = DeploymentStore.shared
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.void)
            .navigationTitle("连接")
            .toolbarColorScheme(.dark, for: .navigationBar)
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
            Label {
                Text("还没有连接任何部署")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.mint.opacity(0.3))
            }
        } description: {
            Text("添加一个部署地址，即可开始游玩。")
                .foregroundStyle(Theme.textSecondary)
        } actions: {
            Button("添加部署") { showingAdd = true }
                .buttonStyle(BorderedProminentTacticalButtonStyle())
                .accessibilityIdentifier("add-deployment-empty")
        }
    }

    private var list: some View {
        List {
            if let healthMessage {
                Text(healthMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(store.deployments) { deployment in
                Button {
                    connect(deployment)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deployment.displayLabel)
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(deployment.baseURL)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if connecting?.id == deployment.id {
                            ProgressView()
                                .tint(Theme.mint)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
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
                    .tint(Theme.mint)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Theme.mintDim)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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

/// 深色战术主按钮样式（mint 填充 + 深色文字，直角）——用于非 PrimaryButton
/// 组件但需要同样观感的 Button（如空态「添加部署」）。
struct BorderedProminentTacticalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.void)
            .frame(minWidth: 120)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .background(Theme.mint.opacity(configuration.isPressed ? 0.8 : 1))
    }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TacPanel(tag: "DEPLOYMENT", title: deployment == nil ? "部署地址" : "编辑部署") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                MonoLabel("URL")
                                TextField("输入部署地址（如 https://stronghold.lunar.ag）", text: $baseURL, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(10)
                                    .background(Theme.base)
                                    .overlay(Rectangle().strokeBorder(Theme.mintDim, lineWidth: 1))
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .accessibilityIdentifier("deployment-url")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                MonoLabel("LABEL")
                                TextField("备注名（可选）", text: $label)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.textPrimary)
                                    .padding(10)
                                    .background(Theme.base)
                                    .overlay(Rectangle().strokeBorder(Theme.mintDim, lineWidth: 1))
                                    .accessibilityIdentifier("deployment-label")
                            }
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(Rectangle().strokeBorder(Theme.danger.opacity(0.6), lineWidth: 1))
                    }
                }
                .padding(16)
            }
            .background(Theme.void)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(deployment == nil ? "添加部署" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .tint(Theme.mint)
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
        .preferredColorScheme(.dark)
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
