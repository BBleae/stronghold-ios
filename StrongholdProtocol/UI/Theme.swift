import SwiftUI

/// Design tokens from docs/design.md §2 (App is dark-only, per design).
enum Theme {
    static let void = Color(hex: 0x0B100D)
    static let base = Color(hex: 0x101512)
    static let panel = Color(hex: 0x161D18)
    static let raised = Color(hex: 0x1C2620)
    static let tileA = Color(hex: 0x232B26)
    static let tileB = Color(hex: 0x28322C)

    static let mint = Color(hex: 0x5CE8AF)
    static let mintBright = Color(hex: 0x7FF0C4)
    static let mintDim = Color(hex: 0x2E4A3E)

    static let amber = Color(hex: 0xE5A83C)
    static let amberDeep = Color(hex: 0xB87F2A)
    static let warnAmber = Color(hex: 0xE8A33D)

    static let danger = Color(hex: 0xE14B3C)
    static let doorRed = Color(hex: 0xFF4A3A)
    static let allyBlue = Color(hex: 0x2E7CD6)
    static let frostBlue = Color(hex: 0x4FA9E8)

    static let textPrimary = Color(hex: 0xF2F7F4)
    static let textSecondary = Color(hex: 0x93A69C)
    static let textDisabled = Color(hex: 0x5A6A61)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// MonoLabel — 等宽英文小标签 (SF Mono, uppercase, letterspaced).
struct MonoLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(1.8)
            .foregroundStyle(Theme.textSecondary)
            .accessibilityLabel(text)
    }
}

/// TacPanel — bg/panel card with 1px border and a mono tag + Chinese title.
struct TacPanel<Content: View>: View {
    let tag: String
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                MonoLabel(tag)
                if let title {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
            }
            content
        }
        .padding(12)
        .background(Theme.panel)
        .overlay(
            Rectangle()
                .strokeBorder(Theme.mintDim, lineWidth: 1)
        )
    }
}

/// BracketFrame — selected-state corner brackets (统一记号).
struct BracketFrame: View {
    var color: Color = Theme.mint
    var lineWidth: CGFloat = 2
    var armLength: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                let a = armLength
                // Top-left
                path.move(to: CGPoint(x: 0, y: a)); path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: a, y: 0))
                // Top-right
                path.move(to: CGPoint(x: w - a, y: 0)); path.addLine(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: w, y: a))
                // Bottom-right
                path.move(to: CGPoint(x: w, y: h - a)); path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: w - a, y: h))
                // Bottom-left
                path.move(to: CGPoint(x: a, y: h)); path.addLine(to: CGPoint(x: 0, y: h))
                path.addLine(to: CGPoint(x: 0, y: h - a))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .square))
        }
        .allowsHitTesting(false)
    }
}

/// PrimaryButton — mint fill + dark text (hatch trim to be added with the
/// battle screens; straight corners per design).
struct PrimaryButton: View {
    let title: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading { ProgressView().tint(Theme.void) }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isDisabled ? Theme.textDisabled : Theme.void)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(isDisabled ? Theme.textDisabled.opacity(0.3) : Theme.mint)
        }
        .disabled(isDisabled)
        .accessibilityIdentifier("primary-button")
    }
}

/// GhostButton — transparent + 1px mintDim border + mint text.
struct GhostButton: View {
    let title: String
    var systemImage: String?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isDisabled ? Theme.textDisabled : Theme.mint)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(isDisabled ? Theme.textDisabled.opacity(0.3) : Color.clear)
            .overlay(Rectangle().strokeBorder(
                isDisabled ? Theme.textDisabled.opacity(0.3) : Theme.mintDim,
                lineWidth: 1
            ))
        }
        .disabled(isDisabled)
    }
}

/// DangerGhostButton — 1px danger border + danger text, square corners
/// （不可逆操作：离开同盟 / 放弃模拟）。
struct DangerGhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .overlay(Rectangle().strokeBorder(Theme.danger, lineWidth: 1))
        }
    }
}

/// HexBadge — hexagonal badge (price / tier / layer).
struct HexBadge: View {
    enum Style {
        case goldOnDark   // 黑底金字 = tier
        case darkOnGold   // 金底深字 = price
        case darkOnMint   // 绿底 = 层数
    }

    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(minWidth: 28, minHeight: 20)
            .background(fill)
            .clipShape(Hexagon())
    }

    private var foreground: Color {
        switch style {
        case .goldOnDark: return Theme.amber
        case .darkOnGold, .darkOnMint: return Theme.void
        }
    }

    private var fill: Color {
        switch style {
        case .goldOnDark: return Theme.raised
        case .darkOnGold: return Theme.amber
        case .darkOnMint: return Theme.mint
        }
    }
}

struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 6
            let point = CGPoint(x: center.x + rect.width / 2 * cos(angle),
                                y: center.y + rect.height / 2 * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// StatusChip — small pill for latency / round / HP.
struct StatusChip: View {
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Rectangle().strokeBorder(color.opacity(0.6), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// 断线重连横幅 — shown at the top of in-session screens while the
/// session is reconnecting with backoff.
struct ReconnectBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.warnAmber)
            Text("连接已断开，正在重连…")
                .font(.footnote)
                .foregroundStyle(Theme.warnAmber)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.raised)
        .overlay(Rectangle().strokeBorder(Theme.warnAmber.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.top, 4)
        .accessibilityIdentifier("reconnect-banner")
    }
}
