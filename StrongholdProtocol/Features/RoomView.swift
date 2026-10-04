import SwiftUI

/// 屏 5：房间（同盟模拟）。M0 scope: seats, key share, ready, host controls,
/// AI teammates, difficulty, start.
struct RoomView: View {
    @ObservedObject var controller: SessionController

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
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    controller.leaveRoom()
                } label: {
                    Text("离开同盟")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let object = controller.roomState?.objectValue,
               let code = object["code"]?.stringValue {
                VStack(alignment: .leading, spacing: 2) {
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
            Spacer()
        }
    }
}

private struct RoomBody: View {
    @ObservedObject var controller: SessionController
    let object: [String: JSON]

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
                        GhostButton(title: "移除 AI", systemImage: "person.badge.minus") {
                            controller.removeBot(seat: Int(botSeat))
                        }
                    }
                }
            }

            Spacer()

            // Ready / start
            HStack(spacing: 12) {
                let ready = mySeat?["ready"]?.boolValue ?? false
                PrimaryButton(title: ready ? "已准备（点此取消）" : "准备就绪") {
                    controller.setReady(!ready)
                }
                if isHost {
                    PrimaryButton(title: allReady ? "开始模拟" : "开始模拟（有人未准备）",
                                  isLoading: false) {
                        controller.startMatch()
                    }
                } else {
                    Text("等待房主开始")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
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
                MonoLabel(seat["playerId"]?.stringValue == myId ? "YOU"
                            : (seat["playerId"]?.stringValue == hostId ? "HOST" : (isBot ? "CPU" : "SEAT 0\(index + 1)")))
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
