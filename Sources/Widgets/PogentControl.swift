import WidgetKit
import SwiftUI
import AppIntents

/// 控制中心与锁屏控件。
struct PogentControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "bot.pogent.control.ask") {
            ControlWidgetButton(action: OpenPogentIntent()) {
                Label("问 pogent", systemImage: "sparkles")
            }
        }
        .displayName("问 pogent")
        .description("打开 pogent，直接开始一个任务")
    }
}
