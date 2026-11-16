import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - 状态小组件

struct PogentEntry: TimelineEntry {
    let date: Date
    let title: String
    let step: String
    let progress: Double
    let running: Bool
}

struct PogentProvider: TimelineProvider {
    func placeholder(in context: Context) -> PogentEntry {
        PogentEntry(date: Date(), title: "整理十月账单", step: "正在生成表格", progress: 0.6, running: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (PogentEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PogentEntry>) -> Void) {
        let entry = placeholder(in: context)
        completion(Timeline(entries: [entry], policy: .after(.now + 900)))
    }
}

struct PogentStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PogentShared.widgetKind, provider: PogentProvider()) { entry in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(entry.running ? Color(hex: 0x5EEAD4) : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text("pogent")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                    Spacer()
                    Text(entry.running ? "执行中" : "空闲")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(entry.step)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: entry.progress)
                    .tint(Color(hex: 0x5EEAD4))
            }
            .containerBackground(for: .widget) {
                Color(hex: 0x0B0B12)
            }
        }
        .configurationDisplayName("pogent 状态")
        .description("看它干到哪一步了。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 灵动岛 / 锁屏

struct PogentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PogentTaskActivity.self) { context in
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color(hex: 0x5EEAD4).opacity(0.18)).frame(width: 34, height: 34)
                    Image(systemName: context.state.awaitingApproval ? "hand.raised.fill" : "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x5EEAD4))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.awaitingApproval ? "等你确认" : context.state.stepTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(context.state.awaitingApproval
                         ? (context.state.approvalPrompt ?? "需要你点一下")
                         : "\(context.attributes.conversationTitle) · \(context.state.stepIndex)/\(max(context.state.stepCount, 1))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if context.state.awaitingApproval {
                    HStack(spacing: 6) {
                        Link(destination: URL(string: "pogent://deny")!) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .padding(7)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }
                        Link(destination: URL(string: "pogent://approve")!) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .padding(7)
                                .background(Color(hex: 0x5EEAD4), in: Circle())
                                .foregroundStyle(Color(hex: 0x07070B))
                        }
                    }
                } else if context.state.finished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: 0x5EEAD4))
                } else {
                    ProgressView().tint(Color(hex: 0x5EEAD4))
                }
            }
            .padding(12)
            .activityBackgroundTint(Color(hex: 0x0B0B12))
            .activitySystemActionForegroundColor(Color(hex: 0x5EEAD4))

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color(hex: 0x5EEAD4))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.awaitingApproval ? "等你确认" : context.state.stepTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(context.attributes.conversationTitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.stepIndex)/\(max(context.state.stepCount, 1))")
                        .font(.system(size: 12, design: .monospaced))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.awaitingApproval {
                        HStack(spacing: 8) {
                            Link(destination: URL(string: "pogent://deny")!) {
                                Text("不允许")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                            Link(destination: URL(string: "pogent://approve")!) {
                                Text("允许")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color(hex: 0x5EEAD4), in: Capsule())
                                    .foregroundStyle(Color(hex: 0x07070B))
                            }
                        }
                    } else {
                        ProgressView(value: Double(context.state.stepIndex), total: Double(max(context.state.stepCount, 1)))
                            .tint(Color(hex: 0x5EEAD4))
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(Color(hex: 0x5EEAD4))
            } compactTrailing: {
                Text("\(context.state.stepIndex)").font(.system(size: 11, design: .monospaced))
            } minimal: {
                Image(systemName: context.state.awaitingApproval ? "hand.raised.fill" : "sparkles")
                    .foregroundStyle(Color(hex: 0x5EEAD4))
            }
        }
    }
}

@main
struct PogentWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PogentStatusWidget()
        PogentLiveActivity()
        PogentControlWidget()
    }
}

// Widget 与主 App 共用同一套颜色。
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
