import SwiftUI

/// 屏 2：大厅 — entered after connecting to a deployment.
/// M0 scope: live WebSocket session (hello/lobby flow) once the protocol
/// layer lands; for now it proves connectivity with a live status line.
struct LobbyView: View {
    let deployment: Deployment

    @State private var status: String = "正在连接…"
    @State private var connected = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: connected ? "checkmark.circle" : "hourglass")
                .font(.system(size: 48))
                .foregroundStyle(connected ? Color.green : Color.secondary)
            Text(status)
                .font(.headline)
            Text(deployment.baseURL)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .navigationTitle("大厅")
        .navigationBarTitleDisplayMode(.inline)
    }
}
