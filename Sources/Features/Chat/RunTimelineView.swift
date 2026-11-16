import SwiftUI

struct RunTimelineView: View {
    let steps: [StepRecord]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PogentTheme.accent)
                    Text("执行过程")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(doneCount)/\(steps.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        StepRow(step: step, isLast: index == steps.count - 1)
                    }
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }

    private var doneCount: Int { steps.filter { $0.status == .done }.count }
}

struct StepRow: View {
    let step: StepRecord
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.16))
                        .frame(width: 18, height: 18)
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                if !isLast {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    SurfaceBadge(surface: step.surface)
                    if step.risk > .safe {
                        RiskBadge(risk: step.risk)
                    }
                    Spacer(minLength: 0)
                    if step.duration > 0 {
                        Text(String(format: "%.1fs", step.duration))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(step.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    private var icon: String {
        switch step.status {
        case .running: "ellipsis"
        case .done: "checkmark"
        case .failed: "xmark"
        case .denied: "hand.raised.fill"
        case .skipped: "minus"
        }
    }

    private var iconColor: Color {
        switch step.status {
        case .running: PogentTheme.amber
        case .done: PogentTheme.accent
        case .failed: PogentTheme.rose
        case .denied: PogentTheme.rose
        case .skipped: .secondary
        }
    }
}

// MARK: - 审批卡片

struct ApprovalCard: View {
    @Environment(AppEnvironment.self) private var app
    let request: ApprovalRequest
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: request.risk.symbol)
                    .font(.system(size: 13, weight: .bold))
                Text(request.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                RiskBadge(risk: request.risk)
            }
            .foregroundStyle(PogentTheme.riskColor(request.risk))

            Text(request.detail)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let appName = request.appName {
                Label(appName, systemImage: "app.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !request.risk.alwaysAsksHuman {
                Toggle("本会话内不再询问同类操作", isOn: $remember)
                    .font(.system(size: 11))
                    .toggleStyle(.switch)
                    .tint(PogentTheme.accent)
            }

            HStack(spacing: 10) {
                Button {
                    app.approvals.resolve(request.id, decision: .denied(reason: "用户拒绝"))
                } label: {
                    Text("不允许")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .foregroundStyle(.primary)

                Button {
                    app.approvals.resolve(request.id, decision: .allowed(rememberForSession: remember))
                } label: {
                    Text("允许这一步")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(PogentTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .foregroundStyle(PogentTheme.ink)
            }
        }
        .padding(15)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PogentTheme.surfaceHigh)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(PogentTheme.riskColor(request.risk).opacity(0.35), lineWidth: 1)
                )
        )
    }
}
