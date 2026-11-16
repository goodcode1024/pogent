import SwiftUI

enum PogentTheme {
    static let accent = Color(hex: 0x5EEAD4)
    static let violet = Color(hex: 0x8B5CF6)
    static let amber = Color(hex: 0xFBBF24)
    static let rose = Color(hex: 0xFB7185)
    static let ink = Color(hex: 0x07070B)
    static let surface = Color(hex: 0x121218)
    static let surfaceHigh = Color(hex: 0x1B1B24)

    static var background: some View {
        ZStack {
            ink
            RadialGradient(
                colors: [accent.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 520
            )
            RadialGradient(
                colors: [violet.opacity(0.20), .clear],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }

    static func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .safe: accent
        case .sensitive: amber
        case .destructive: rose
        case .financial: Color(hex: 0xFF4D6D)
        }
    }

    static func surfaceColor(_ surface: ExecutionSurface) -> Color {
        switch surface {
        case .native: accent
        case .shell: violet
        case .ui: amber
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 22
    var stroke: Color = .white.opacity(0.10)

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(PogentTheme.surface.opacity(0.55))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 0.8)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 22, stroke: Color = .white.opacity(0.10)) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, stroke: stroke))
    }

    func pogentBackground() -> some View {
        background(PogentTheme.background)
    }
}

struct SurfaceBadge: View {
    let surface: ExecutionSurface

    var body: some View {
        Text(surface.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(PogentTheme.surfaceColor(surface).opacity(0.18), in: Capsule())
            .foregroundStyle(PogentTheme.surfaceColor(surface))
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: risk.symbol).font(.system(size: 9, weight: .bold))
            Text(risk.title).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(PogentTheme.riskColor(risk).opacity(0.16), in: Capsule())
        .foregroundStyle(PogentTheme.riskColor(risk))
    }
}
