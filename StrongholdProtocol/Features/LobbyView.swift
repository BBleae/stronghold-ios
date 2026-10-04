import SwiftUI

/// 屏 3：大厅 —「选择模拟协议」。M0 flow scope: nickname, mode, difficulty,
/// create room, join by 4-letter key. Layout follows design.md S4 (simplified
/// until the design pass).
struct LobbyView: View {
    let deployment: Deployment

    @StateObject private var controller: SessionController
    @State private var nickname: String = IdentityStore().lastName
    @State private var mode: String = "coop"
    @State private var difficulty: GameDifficulty = .normal
    @State private var roomKey: String = ""
    @State private var showRoom = false

    init(deployment: Deployment) {
        self.deployment = deployment
        _controller = StateObject(wrappedValue: SessionController(deployment: deployment))
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            switch controller.phase {
            case .idle, .connecting, .failed:
                connectSection
            case .connected:
                mainSection
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.void)
        .navigationTitle("选择模拟协议")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(isPresented: $showRoom) {
            RoomView(controller: controller)
        }
        .onChange(of: controller.roomState) { _, state in
            if state != nil { showRoom = true }
        }
        .overlay(alignment: .top) {
            if let toast = controller.toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.raised)
                    .overlay(Rectangle().strokeBorder(Theme.mintDim, lineWidth: 1))
                    .padding(.top, 4)
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        controller.toast = nil
                    }
            }
        }
    }

    private var header: some View {
        HStack {
            StatusChip(text: deployment.displayLabel)
            Spacer()
            if let identity = controller.identity {
                MonoLabel(identity.playerId)
            }
        }
    }

    private var connectSection: some View {
        VStack(spacing: 12) {
            if case .failed(let reason) = controller.phase {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
            TextField("输入你的昵称", text: $nickname, prompt: Text("输入你的昵称").foregroundStyle(Theme.textDisabled))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .padding(10)
                .background(Theme.base)
                .overlay(Rectangle().strokeBorder(Theme.mintDim, lineWidth: 1))
                .disableAutocorrection(true)
                .accessibilityIdentifier("nickname")
            PrimaryButton(title: controller.phase == .connecting ? "正在连接…" : "连接",
                          isLoading: controller.phase == .connecting) {
                let name = nickname.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                controller.start(name: String(name.prefix(12)))
            }
            .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty || controller.phase == .connecting)
        }
        .frame(maxWidth: 420)
    }

    private var mainSection: some View {
        VStack(spacing: 12) {
            TacPanel(tag: "SIMULATION MODE", title: "模拟方式") {
                HStack(spacing: 12) {
                    modeCard(title: "独立模拟", tag: "SOLO", systemImage: "person.fill", selected: mode == "solo")
                        .onTapGesture { mode = "solo" }
                        .accessibilityIdentifier("mode-solo")
                    modeCard(title: "同盟模拟", tag: "CO-OP", systemImage: "person.2.fill", selected: mode == "coop")
                        .onTapGesture { mode = "coop" }
                        .accessibilityIdentifier("mode-coop")
                }
                .padding(.top, 2)
            }
            TacPanel(tag: "DIFFICULTY", title: "模拟难度") {
                HStack(spacing: 8) {
                    ForEach(GameDifficulty.allCases, id: \.self) { option in
                        Button {
                            difficulty = option
                        } label: {
                            HStack(spacing: 6) {
                                if difficulty == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                Text(option.label)
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(difficulty == option ? Theme.amber : Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 40)
                            .background(difficulty == option ? Theme.amber.opacity(0.12) : Theme.base)
                            .overlay(
                                Rectangle().strokeBorder(
                                    difficulty == option ? Theme.amber : Theme.mintDim,
                                    lineWidth: difficulty == option ? 1.5 : 1
                                )
                            )
                            .overlay {
                                if difficulty == option {
                                    BracketFrame(color: Theme.amber).padding(3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if mode == "coop" {
                TacPanel(tag: "ALLIANCE KEY", title: "加入同盟") {
                    HStack(spacing: 8) {
                        TextField("输入 4 位房间密钥", text: $roomKey, prompt: Text("输入 4 位房间密钥").foregroundStyle(Theme.textDisabled))
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.mint)
                            .frame(minHeight: 40)
                            .padding(.horizontal, 10)
                            .background(Theme.base)
                            .overlay(Rectangle().strokeBorder(Theme.mintDim, lineWidth: 1))
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                            .accessibilityIdentifier("room-key")
                        GhostButton(title: "加入同盟") {
                            controller.joinRoom(code: roomKey)
                        }
                        .disabled(roomKey.count < 4)
                    }
                }
            }
            PrimaryButton(title: mode == "solo" ? "开始独立模拟" : "创建同盟") {
                controller.createRoom(mode: mode, difficulty: difficulty)
            }
        }
        .frame(maxWidth: 720)
    }

    private func modeCard(title: String, tag: String, systemImage: String, selected: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(selected ? Theme.mint : Theme.textSecondary)
                .frame(minHeight: 34)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            MonoLabel(tag)
            if selected {
                Text("已选定")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(Theme.mint)
            } else {
                MonoLabel(" ")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 88)
        .background(Theme.panel)
        .overlay(Rectangle().strokeBorder(selected ? Theme.mint : Theme.mintDim, lineWidth: selected ? 1.5 : 1))
        .overlay {
            if selected { BracketFrame().padding(3) }
        }
    }
}
