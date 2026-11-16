import Foundation
import SwiftData
import Observation

/// 依赖装配。整个 App 只有这一个入口创建服务。
@MainActor
@Observable
final class AppEnvironment {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    let ledger: AuditLedger
    let approvals: ApprovalEngine
    let registry = ToolRegistry()
    let shell: ShellSession
    let control: DeviceControlService
    let runtime: AgentRuntime
    let browser = BrowserService()
    let routines: RoutineStore
    let plugins = PluginRuntime()
    let marketplace = MarketplaceClient()
    let remote = RemoteSessionService()
    let bots: BotCoordinator
    let scheduler: BotScheduler

    var modelConfig: ModelConfig {
        didSet { persistConfig() }
    }
    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "pogent.onboarded") }
    }

    init(inMemory: Bool = false) {
        container = PogentStore.container(inMemory: inMemory)

        let workspace = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pogent", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        ledger = AuditLedger()
        approvals = ApprovalEngine(ledger: ledger)
        shell = ShellSession(workspace: workspace)
        routines = RoutineStore(workspace: workspace)
        scheduler = BotScheduler(workspace: workspace)

        #if DEBUG
        control = DeviceControlService(transport: DemoAutomationTransport())
        #else
        control = DeviceControlService(transport: SystemAutomationTransport())
        #endif

        let config = Self.loadConfig()
        modelConfig = config
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "pogent.onboarded")

        runtime = AgentRuntime(
            registry: registry,
            approvals: approvals,
            ledger: ledger,
            control: control,
            shell: shell,
            modelConfig: config
        )

        bots = BotCoordinator(context: container.mainContext, runtime: runtime)

        registerTools()
    }

    private func registerTools() {
        registry.register([
            // 界面操控（Poki 的 look / do）
            LookTool(control: control),
            DoTool(control: control, ledger: ledger),
            LaunchAppTool(control: control),

            // 系统能力
            CalendarTool(),
            ReminderTool(),
            ContactTool(),
            HealthTool(),
            PhotoTool(),
            MapTool(),
            MusicTool(),
            MessageTool(),
            ClipboardTool(),
            NotificationTool(),
            ShortcutTool(),
            HomeTool(),

            // 本机运行时
            ShellTool(shell: shell),
            ReadFileTool(shell: shell),
            WriteFileTool(shell: shell),
            ListFilesTool(shell: shell),
            GitTool(shell: shell),
            MediaTool(shell: shell),

            // 网页
            WebFetchTool(),
            BrowserTool(browser: browser)
        ])
    }

    // MARK: 配置

    private func persistConfig() {
        runtime.modelConfig = modelConfig
        if let data = try? JSONEncoder().encode(modelConfig) {
            UserDefaults.standard.set(data, forKey: "pogent.modelConfig")
        }
    }

    private static func loadConfig() -> ModelConfig {
        guard let data = UserDefaults.standard.data(forKey: "pogent.modelConfig"),
              let config = try? JSONDecoder().decode(ModelConfig.self, from: data) else {
            return .default
        }
        return config
    }

    // MARK: 便捷

    func bootstrapConversation() -> Conversation {
        let descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let conversation = Conversation(title: "新对话")
        context.insert(conversation)
        try? context.save()
        return conversation
    }

    var workspaceURL: URL { shell.workspace }
}
