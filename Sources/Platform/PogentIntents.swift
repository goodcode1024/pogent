import AppIntents
import Foundation

/// Siri / 快捷指令的入口。任务写进共享区，App 打开后自动开始。
///
/// 注意：AppIntent 的 title/description 必须是计算属性。写成 `static var x = ...`
/// 在 Swift 6 的严格并发下会报 "not concurrency-safe ... global shared mutable state"。
struct AskPogentIntent: AppIntent {
    static var title: LocalizedStringResource { "让 pogent 做事" }
    static var description: IntentDescription { IntentDescription("把一句话交给 pogent，在本机执行。") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "任务", description: "例如：把明天的牙医预约加到日历")
    var prompt: String

    init() {}

    init(prompt: String) {
        self.prompt = prompt
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(prompt, forKey: "pogent.pendingPrompt")
        return .result(dialog: "好，交给 pogent 了。")
    }
}

/// 锁屏 / 通知上的“允许”也能走这里。
struct ApprovePogentIntent: AppIntent {
    static var title: LocalizedStringResource { "允许 pogent 的这一步" }
    static var description: IntentDescription { IntentDescription("放行当前等待确认的操作。") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(true, forKey: "pogent.approveRequested")
        return .result(dialog: "已允许。")
    }
}

struct DenyPogentIntent: AppIntent {
    static var title: LocalizedStringResource { "拒绝 pogent 的这一步" }
    static var description: IntentDescription { IntentDescription("拒绝当前等待确认的操作。") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(false, forKey: "pogent.approveRequested")
        UserDefaults.standard.set(true, forKey: "pogent.denyRequested")
        return .result(dialog: "已拒绝。")
    }
}

struct PogentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskPogentIntent(),
            phrases: [
                "让 \(.applicationName) 做事",
                "问 \(.applicationName)"
            ],
            shortTitle: "交给 pogent",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: ApprovePogentIntent(),
            phrases: ["允许 \(.applicationName) 继续"],
            shortTitle: "允许这一步",
            systemImageName: "checkmark.circle"
        )
    }
}
