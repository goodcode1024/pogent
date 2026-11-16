import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatMessage.createdAt, order: .forward) private var allMessages: [ChatMessage]

    @State private var conversation: Conversation?
    @State private var draft = ""
    @State private var showVoice = false
    @State private var showSkills = false
    @State private var showConversations = false
    @State private var showLibrary = false
    @State private var planMode = false
    @State private var pendingPlan: String?
    @State private var planGoal = ""
    @FocusState private var composerFocused: Bool

    private var messages: [ChatMessage] {
        guard let conversation else { return [] }
        return allMessages.filter { $0.conversationID == conversation.id }
    }

    var body: some View {
        ZStack {
            PogentTheme.background

            VStack(spacing: 0) {
                header
                transcript
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .task {
            if conversation == nil {
                conversation = app.bootstrapConversation()
            }
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [PogentTheme.accent, PogentTheme.violet],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Text("P")
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .foregroundStyle(PogentTheme.ink)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("pogent")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                HStack(spacing: 4) {
                    Circle()
                        .fill(app.runtime.isRunning ? PogentTheme.amber : PogentTheme.accent)
                        .frame(width: 5, height: 5)
                    Text(app.runtime.isRunning ? "正在执行" : "\(app.registry.count) 个工具 · \(app.memory.items.count) 条记忆")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                Button("新建对话", systemImage: "square.and.pencil") {
                    let new = Conversation(title: "新对话")
                    context.insert(new)
                    try? context.save()
                    conversation = new
                }
                Button("会话列表", systemImage: "list.bullet.rectangle") {
                    showConversations = true
                }
                Button("存为技能", systemImage: "square.stack.3d.up") {
                    saveSkill()
                }
                Button("技能与审计", systemImage: "square.stack.3d.up.fill") {
                    showLibrary = true
                }
                Toggle("计划模式", systemImage: "list.clipboard", isOn: $planMode)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: 消息

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty && !app.runtime.isRunning {
                        emptyState
                    }

                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if app.runtime.isRunning {
                        if !app.runtime.streamingText.isEmpty {
                            streamingBubble
                        }
                        RunTimelineView(steps: app.runtime.steps)
                            .padding(.horizontal, 18)
                    }

                    if let pendingPlan {
                        PlanCard(
                            plan: pendingPlan,
                            onRun: {
                                let goal = planGoal
                                self.pendingPlan = nil
                                Task {
                                    await app.runtime.submit("\(goal)\n\n按上面的计划执行。", conversation: conversation ?? app.bootstrapConversation(), context: context)
                                }
                            },
                            onCancel: { self.pendingPlan = nil }
                        )
                        .padding(.horizontal, 18)
                    }

                    if let request = app.approvals.pending.first {
                        ApprovalCard(request: request)
                            .padding(.horizontal, 18)
                    }

                    if let error = app.runtime.lastError, !app.runtime.isRunning {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(PogentTheme.rose)
                            .padding(.horizontal, 20)
                    }

                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in scroll(proxy) }
            .onChange(of: app.runtime.streamingText) { _, _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var streamingBubble: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            Text(app.runtime.streamingText)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .padding(14)
                .glassCard(cornerRadius: 18)
            Spacer(minLength: 30)
        }
        .padding(.horizontal, 18)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(PogentTheme.surfaceHigh).frame(width: 28, height: 28)
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(PogentTheme.accent)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("把一整件事交给它")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("读屏、点按、跑命令、调系统 API。能用接口就不点界面，点界面每一步都给你看。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                suggestion("明早 7 点叫我，然后告诉我今天天气", icon: "alarm")
                suggestion("记住我不吃香菜，以后推荐餐厅注意", icon: "brain")
                suggestion("把这个月的账单整理成表格，发给我老婆", icon: "tablecells")
                suggestion("看一下我刚拍的那张收据，把金额列出来", icon: "doc.viewfinder")
            }

            HStack(spacing: 8) {
                capabilityChip("\(app.registry.count) 个工具", "square.grid.2x2")
                capabilityChip("三级能力路由", "arrow.triangle.branch")
                capabilityChip("全程可回放", "clock.arrow.circlepath")
            }
        }
        .padding(20)
        .padding(.top, 10)
    }

    private func suggestion(_ text: String, icon: String) -> some View {
        Button {
            draft = text
            composerFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PogentTheme.accent)
                    .frame(width: 22)
                Text(text)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(12)
            .glassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    private func capabilityChip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: Capsule())
    }

    // MARK: 输入

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("语音输入", systemImage: "waveform") { showVoice = true }
                    Button("技能", systemImage: "square.stack.3d.up") { showSkills = true }
                    Button("计划模式", systemImage: "list.clipboard") {
                        planMode.toggle()
                    }
                    Button("会话列表", systemImage: "list.bullet.rectangle") { showConversations = true }
                } label: {
                    Image(systemName: planMode ? "list.clipboard.fill" : "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(planMode ? PogentTheme.amber : .secondary)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.06), in: Circle())
                }

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("让 pogent 做点什么", text: $draft, axis: .vertical)
                        .focused($composerFocused)
                        .lineLimit(1...5)
                        .font(.system(size: 15))

                    Button {
                        showVoice = true
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 20)

                Button(action: send) {
                    ZStack {
                        Circle()
                            .fill(canSend ? PogentTheme.accent : Color.white.opacity(0.08))
                            .frame(width: 36, height: 36)
                        Image(systemName: app.runtime.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(canSend ? PogentTheme.ink : .secondary)
                    }
                }
                .disabled(!canSend && !app.runtime.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
        }
        .sheet(isPresented: $showVoice) {
            QuickVoiceSheet { text in
                if draft.isEmpty { draft = text } else { draft += " " + text }
            }
            .presentationDetents([.height(300)])
        }
        .sheet(isPresented: $showConversations) {
            ConversationListView { conversation in
                self.conversation = conversation
                showConversations = false
            }
        }
        .sheet(isPresented: $showLibrary) {
            NavigationStack { LibraryView() }
        }
        .sheet(isPresented: $showSkills) {
            SkillPicker { text in
                draft = text
                showSkills = false
                composerFocused = true
            }
            .presentationDetents([.medium])
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !app.runtime.isRunning
    }

    private func send() {
        if app.runtime.isRunning {
            app.runtime.stop()
            return
        }
        guard canSend, let conversation else { return }
        let text = draft
        draft = ""

        if planMode {
            planGoal = text
            Task {
                pendingPlan = await app.runtime.requestPlan(text, conversation: conversation, context: context)
                planMode = false
            }
            return
        }

        Task {
            await app.runtime.submit(text, conversation: conversation, context: context)
        }
    }

    private func saveSkill() {
        guard let conversation else { return }
        let compiler = SkillCompiler(context: context, ledger: app.ledger)
        _ = try? compiler.compile(
            runID: app.runtime.currentRun?.id ?? "",
            goal: conversation.lastText,
            originApp: app.control.originAppName,
            steps: app.runtime.steps
        )
    }
}

// MARK: - 气泡

struct MessageBubble: View {
    @Environment(AppEnvironment.self) private var app
    let message: ChatMessage

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(PogentTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [PogentTheme.accent, Color(hex: 0x7DD3FC)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            .padding(.horizontal, 18)
        } else {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(PogentTheme.surfaceHigh).frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PogentTheme.accent)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey(message.text))
                        .font(.system(size: 15))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(message.createdAt, style: .time)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = message.text
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                        }
                        .foregroundStyle(.tertiary)
                        Button {
                            app.synthesizer.speak(message.text)
                        } label: {
                            Image(systemName: "speaker.wave.2").font(.system(size: 10))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 18)
                .contextMenu {
                    Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    Button("朗读", systemImage: "speaker.wave.2") { app.synthesizer.speak(message.text) }
                    Button("停止朗读", systemImage: "speaker.slash") { app.synthesizer.stop() }
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 18)
        }
    }
}

// MARK: - 计划卡

struct PlanCard: View {
    let plan: String
    var onRun: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "list.clipboard.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PogentTheme.amber)
                Text("计划待确认")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("还没有执行任何工具")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Text(LocalizedStringKey(plan))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(action: onRun) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        Text("开始执行").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(PogentTheme.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(PogentTheme.accent)
                }
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text("不用了")
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18, stroke: PogentTheme.amber.opacity(0.3))
    }
}

// MARK: - 语音输入

struct QuickVoiceSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    var onResult: (String) -> Void

    @State private var pressing = false

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.white.opacity(0.2)).frame(width: 36, height: 4).padding(.top, 8)

            Text(app.speech.isRecording ? "松手结束" : "按住说话")
                .font(.system(size: 15, weight: .semibold))

            ScrollView {
                Text(app.speech.transcript.isEmpty ? "说的话会出现在这里" : app.speech.transcript)
                    .font(.system(size: 15))
                    .foregroundStyle(app.speech.transcript.isEmpty ? .tertiary : .primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
            }
            .frame(maxHeight: 100)

            if let error = app.speech.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(PogentTheme.rose)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            ZStack {
                Circle()
                    .fill(app.speech.isRecording ? PogentTheme.rose.opacity(0.22) : PogentTheme.accent.opacity(0.14))
                    .frame(width: 78, height: 78)
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(app.speech.isRecording ? PogentTheme.rose : PogentTheme.accent)
            }
            .scaleEffect(pressing ? 0.92 : 1)
            .animation(.spring(response: 0.22), value: pressing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        Presentation.haptic(.rigid)
                        Task { await app.speech.start() }
                    }
                    .onEnded { _ in
                        guard pressing else { return }
                        pressing = false
                        let text = app.speech.stop()
                        guard !text.isEmpty else { return }
                        onResult(text)
                        dismiss()
                    }
            )

            Text("识别在本机完成。没网也能用，前提是系统下过中文语音包。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PogentTheme.surface)
    }
}

// MARK: - 技能选择

struct SkillPicker: View {
    @Query(sort: \SkillRecord.createdAt, order: .reverse) private var skills: [SkillRecord]
    var onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("从一次运行生成") {
                    Text("跑完一个任务后，右上角菜单里点「存为技能」，下次一句话重放。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Section("已保存") {
                    if skills.isEmpty {
                        Text("还没有技能").foregroundStyle(.secondary)
                    }
                    ForEach(skills) { skill in
                        Button {
                            onPick(skill.goalTemplate)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skill.name).font(.system(size: 15, weight: .medium))
                                Text(skill.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("技能")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
