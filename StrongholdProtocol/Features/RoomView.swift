import SwiftUI

/// 屏 5：房间（同盟模拟）。M0 scope: seats, key share, ready, host controls,
/// AI teammates, difficulty, start.
struct RoomView: View {
    @ObservedObject var controller: SessionController
    @State private var showingLeaveConfirm = false

    var body: some View {
        VStack(spacing: 16) {
            header
            if let state = controller.roomState, case .object(let object) = state {
                RoomBody(controller: controller, object: object)
            } else {
                ProgressView()
                    .tint(Theme.mint)
            }
            Spacer()
        }
        .padding(16)
        .background(Theme.void)
        .overlay(alignment: .top) {
            if controller.isReconnecting {
                ReconnectBanner()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("确定离开同盟吗？", isPresented: $showingLeaveConfirm) {
            Button("确认", role: .destructive) {
                controller.leaveRoom()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // 离开 = 红方钮（design.md S5），方形直角，不用系统胶囊。
            DangerGhostButton(title: "离开同盟") {
                showingLeaveConfirm = true
            }
            Spacer()
            if let object = controller.roomState?.objectValue,
               let code = object["code"]?.stringValue {
                VStack(alignment: .trailing, spacing: 2) {
                    MonoLabel("ROOM KEY")
                    HStack(spacing: 8) {
                        Text("房间密钥 \(code)")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(Theme.mint)
                        Button {
                            UIPasteboard.general.string = code
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel("复制房间密钥")
                    }
                }
            }
        }
    }
}

private struct RoomBody: View {
    @ObservedObject var controller: SessionController
    let object: [String: JSON]
    @State private var confirmRemoveBot = false

    private var seats: [JSON] {
        object["seats"]?.arrayValue ?? []
    }

    private var hostId: String? { object["hostId"]?.stringValue }
    private var myId: String? { controller.playerId }
    private var isHost: Bool { hostId != nil && hostId == myId }
    private var inMatch: Bool { object["inMatch"]?.boolValue ?? false }

    private var allReady: Bool {
        let filled = seats.compactMap { $0.objectValue }.filter { $0["isBot"]?.boolValue == false }
        return !filled.isEmpty && filled.allSatisfy { $0["ready"]?.boolValue == true }
    }

    private var mySeat: [String: JSON]? {
        seats.compactMap { $0.objectValue }.first { $0["playerId"]?.stringValue == myId }
    }

    var body: some View {
        VStack(spacing: 16) {
            // Seats
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    seatCard(index)
                }
            }

            if isHost {
                HStack(spacing: 8) {
                    GhostButton(title: "添加 AI 队友", systemImage: "person.badge.plus") {
                        controller.addBot()
                    }
                    if let botSeat = seats.compactMap({ $0.objectValue }).first(where: { $0["isBot"]?.boolValue == true })?["seat"]?.intValue {
                        GhostButton(
                            title: confirmRemoveBot ? "再点一次确认" : "移除 AI",
                            systemImage: "person.badge.minus"
                        ) {
                            if confirmRemoveBot {
                                confirmRemoveBot = false
                                controller.removeBot(seat: Int(botSeat))
                            } else {
                                confirmRemoveBot = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2.5))
                                    confirmRemoveBot = false
                                }
                            }
                        }
                    }
                }
            }

            Spacer()

            // Ready / start
            HStack(spacing: 12) {
                let ready = mySeat?["ready"]?.boolValue ?? false
                PrimaryButton(title: ready ? "已准备" : "准备就绪") {
                    controller.setReady(!ready)
                }
                if isHost {
                    VStack(spacing: 6) {
                        PrimaryButton(title: "开始模拟", isDisabled: !allReady) {
                            controller.startMatch()
                        }
                        if !allReady {
                            Text("还有队友未准备")
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                } else {
                    PrimaryButton(title: "等待房主开始", isDisabled: true) {}
                }
            }
        }
    }

    @ViewBuilder
    private func seatCard(_ index: Int) -> some View {
        let seat = index < seats.count ? seats[index].objectValue : nil
        VStack(spacing: 6) {
            if let seat {
                let isBot = seat["isBot"]?.boolValue ?? false
                let ready = seat["ready"]?.boolValue ?? false
                let connected = seat["connected"]?.boolValue ?? false
                Image(systemName: isBot ? "cpu" : "person.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(ready ? Theme.mint : (connected ? Theme.textPrimary : Theme.warnAmber))
                Text(seat["name"]?.stringValue ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 6) {
                    MonoLabel("SEAT 0\(index + 1)")
                    if isBot {
                        MonoLabel("CPU")
                    } else if seat["playerId"]?.stringValue == hostId
                        && seat["playerId"]?.stringValue == myId {
                        MonoLabel("HOST·YOU")
                    } else if seat["playerId"]?.stringValue == hostId {
                        MonoLabel("HOST")
                    } else if seat["playerId"]?.stringValue == myId {
                        MonoLabel("YOU")
                    }
                }
                // 座位状态（copy.md 屏 3b）：已准备 / 待命中；自己的已准备座位
                // 额外提供「点此取消准备」小签，点按回「待命中」。
                if ready {
                    HStack(spacing: 6) {
                        Text("已准备")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.mint)
                        if seat["playerId"]?.stringValue == myId {
                            Button {
                                controller.setReady(false)
                            } label: {
                                Text("点此取消准备")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("待命中")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textDisabled)
                MonoLabel("EMPTY")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 96)
        .background(Theme.panel)
        .overlay(
            Rectangle().strokeBorder(
                seat != nil ? Theme.mintDim : Theme.mintDim.opacity(0.5),
                style: StrokeStyle(lineWidth: 1, dash: seat == nil ? [4, 4] : [])
            )
        )
    }
}
