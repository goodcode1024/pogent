import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context

    @AppStorage("cap.calendar") private var calendarEnabled = true
    @AppStorage("cap.reminders") private var remindersEnabled = true
    @AppStorage("cap.contacts") private var contactsEnabled = true
    @AppStorage("cap.health") private var healthEnabled = false
    @AppStorage("cap.photos") private var photosEnabled = true
    @AppStorage("cap.home") private var homeEnabled = false
    @AppStorage("cap.clipboard") private var clipboardEnabled = false
    @AppStorage("cap.background") private var backgroundEnabled = true

    @State private var apiKey = ""
    @State private var showAudit = false
    @State private var showRemote = false

    var body: some View {
        ZStack {
            PogentTheme.background
            ScrollView {
                VStack(spacing: 16) {
                    header
                    modelSection
                    approvalSection
                    capabilitySection
                    controlSection
                    remoteSection
                    dataSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
        }
        .task { apiKey = KeychainStore.apiKey(for: app.modelConfig.kind.rawValue) ?? "" }
        .sheet(isPresented: $showAudit) { AuditSheet() }
        .sheet(isPresented: $showRemote) { RemoteSheet() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("iOS 27 · 只有一条执行路径，没有旧版本兼容层。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: 模型

    private var modelSection: some View {
        section("模型") {
            Picker("来源", selection: Binding(
                get: { app.modelConfig.kind },
                set: { app.modelConfig.kind = $0 }
            )) {
                Text("端侧优先").tag(ModelConfig.Kind.onDevice)
                Text("自己的 API").tag(ModelConfig.Kind.openAICompatible)
            }
            .pickerStyle(.segmented)

            if app.modelConfig.kind == .openAICompatible {
                labeledField("接口地址", text: Binding(
                    get: { app.modelConfig.baseURL },
                    set: { app.modelConfig.baseURL = $0 }
                ), placeholder: "https://api.openai.com/v1")

                labeledField("模型", text: Binding(
                    get: { app.modelConfig.model },
                    set: { app.modelConfig.model = $0 }
                ), placeholder: "gpt-4.1")

                HStack {
                    SecureField("API Key", text: $apiKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never)
                    Button("保存") {
                        KeychainStore.save(apiKey, for: app.modelConfig.kind.rawValue)
                    }
                    .font(.system(size: 11, weight: .semibold))
                }

                Toggle(isOn: Binding(
                    get: { app.modelConfig.shouldEchoReasoning },
                    set: { app.modelConfig.echoReasoning = $0 }
                )) {
                    Label("回传思考内容", systemImage: "brain")
                        .font(.system(size: 12))
                }
                .tint(PogentTheme.accent)

                Text("思考模型（DeepSeek V3.2、GLM、Kimi 等）工具调用后必须把 reasoning_content 原样带回，关掉会报 HTTP 400。普通模型遇到这个字段报错时再关。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("端侧模型负责分类、摘要和风险预判；复杂规划交给你的大模型。屏幕内容只在需要时才发出去。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 审批

    private var approvalSection: some View {
        section("审批") {
            Picker("方式", selection: Binding(
                get: { app.approvals.policy.mode },
                set: { app.approvals.policy.mode = $0 }
            )) {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("敏感度").font(.system(size: 12))
                    Spacer()
                    Text(app.approvals.policy.sensitivity.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PogentTheme.amber)
                }
                Slider(
                    value: Binding(
                        get: { Double(app.approvals.policy.sensitivity.rawValue) },
                        set: { app.approvals.policy.sensitivity = ApprovalSensitivity(rawValue: Int($0.rounded())) ?? .balanced }
                    ),
                    in: 0...3,
                    step: 1
                )
                .tint(PogentTheme.amber)
                HStack {
                    Text("宽松").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("全部询问").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text("付款阈值").font(.system(size: 12))
                Spacer()
                Stepper("¥\(Int(truncating: NSDecimalNumber(decimal: app.approvals.policy.paymentThreshold)))",
                        value: Binding(
                            get: { Double(truncating: NSDecimalNumber(decimal: app.approvals.policy.paymentThreshold)) },
                            set: { app.approvals.policy.paymentThreshold = Decimal($0) }
                        ),
                        in: 0...5000, step: 50)
                    .font(.system(size: 12, design: .monospaced))
            }

            Text("资金、删除、Wallet 永远人工确认；密码和验证码会转交给你本人。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 能力

    private var capabilitySection: some View {
        section("本机能力") {
            capRow("日历", "calendar", $calendarEnabled)
            capRow("提醒事项", "checklist", $remindersEnabled)
            capRow("通讯录", "person.crop.circle", $contactsEnabled)
            capRow("健康", "heart.fill", $healthEnabled)
            capRow("照片", "photo.on.rectangle", $photosEnabled)
            capRow("家庭", "house.fill", $homeEnabled)
            capRow("剪贴板", "doc.on.clipboard", $clipboardEnabled)
            capRow("后台继续跑", "bolt.fill", $backgroundEnabled)
        }
    }

    private func capRow(_ title: String, _ icon: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
        }
        .tint(PogentTheme.accent)
    }

    // MARK: 操控

    private var controlSection: some View {
        section("操控手机") {
            HStack(spacing: 8) {
                Circle().fill(PogentTheme.accent).frame(width: 6, height: 6)
                Text("iOS 27 原生自动化服务")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("就绪").font(.system(size: 10, weight: .semibold)).foregroundStyle(PogentTheme.accent)
            }

            Text("不再需要：开发者模式、7 天重签、Mac/Windows 安装器、VPN 回环隧道、第三方 iCTRL。iOS 27 直接用系统服务，装完就能用。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("一次最多动作").font(.system(size: 12))
                Spacer()
                Stepper("\(app.control.maxActionsPerCall)", value: Binding(
                    get: { app.control.maxActionsPerCall },
                    set: { app.control.maxActionsPerCall = $0 }
                ), in: 1...20)
                .font(.system(size: 12, design: .monospaced))
            }
        }
    }

    // MARK: 远程

    private var remoteSection: some View {
        section("远程会话") {
            HStack(spacing: 8) {
                Circle()
                    .fill(app.remote.isConnected ? PogentTheme.accent : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(app.remote.isConnected ? "已连接" : "未连接")
                    .font(.system(size: 12))
                Spacer()
                Button("管理") { showRemote = true }
                    .font(.system(size: 11, weight: .semibold))
            }
            Text("把电脑和服务器上的 Codex、Claude Code、DSH 会话并进同一个列表。不登录不会发生任何事。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 数据

    private var dataSection: some View {
        section("数据") {
            HStack {
                Text("审计记录").font(.system(size: 12))
                Spacer()
                Text("\(app.ledger.entries.count) 条")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("查看") { showAudit = true }
                    .font(.system(size: 11, weight: .semibold))
            }

            ShareLink(item: app.ledger.export()) {
                Label("导出审计账本", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12))
            }

            Button(role: .destructive) {
                app.ledger.clear()
            } label: {
                Label("清空审计记录", systemImage: "trash")
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        section("关于") {
            HStack {
                Text("版本").font(.system(size: 12))
                Spacer()
                Text("1.0.0 (1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Text("最低系统").font(.system(size: 12))
                Spacer()
                Text("iOS 27.0").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Text("工具").font(.system(size: 12))
                Spacer()
                Text("\(app.registry.count) 个").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("这一版删掉了")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(["XCTest / WebDriverAgent 会话", "10.7.0.1 回环隧道与 VPN 要求",
                         "Mac / Windows 安装器与 7 天重签", "iOS 18–26 的可用性分支", "iCTRL 侧载与开发者模式", "WebView 套壳的官方 Web UI"], id: \.self) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "minus.circle").font(.system(size: 9)).foregroundStyle(PogentTheme.rose)
                        Text(item).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: 组件

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

// MARK: - 审计

struct AuditSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.ledger.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.title).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(entry.date, style: .time).font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Text(entry.detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("审计记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 远程

struct RemoteSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            List {
                Section("配对") {
                    TextField("输入电脑上显示的 6 位配对码", text: $code)
                        .font(.system(size: 14, design: .monospaced))
                    Button("连接") {
                        Task { try? await app.remote.pair(code: code) }
                    }
                    .disabled(code.count < 4)
                }

                Section("会话") {
                    if app.remote.sessions.isEmpty {
                        Text("连接后，远程会话会出现在这里。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(app.remote.sessions) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: session.symbol).font(.system(size: 11))
                                Text(session.agent.title).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(session.state.rawValue).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Text(session.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button("断开") { app.remote.disconnect() }
                        .foregroundStyle(PogentTheme.rose)
                }
            }
            .navigationTitle("远程会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
