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
                    Text(app.runtime.isRunning ? "正在执行" : "\(app.registry.count) 个工具 · iOS 27")
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
                Button("存为技能", systemImage: "square.stack.3d.up") {
                    saveSkill()
                }
                Button("审批记录", systemImage: "checklist") {}
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
                suggestion("把明天的牙医预约加到日历，提前一小时提醒", icon: "calendar.badge.plus")
                suggestion("把这个月的账单整理成表格，发给我老婆", icon: "tablecells")
                suggestion("在外卖 App 里点一份牛肉面，先给我看购物车", icon: "takeoutbag.and.cup.and.straw")
            }

            HStack(spacing: 8) {
                capabilityChip("26 个工具", "square.grid.2x2")
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
                Button {
                    showSkills = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
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
            VoiceSheet()
                .presentationDetents([.height(220)])
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
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 18)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 18)
        }
    }
}

// MARK: - 语音

struct VoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var level: CGFloat = 0.2

    var body: some View {
        VStack(spacing: 20) {
            Capsule().fill(Color.white.opacity(0.2)).frame(width: 36, height: 4).padding(.top, 8)
            Text("按住说话").font(.system(size: 17, weight: .semibold))
            Text("松手转成文字发出去。识别用你自己的 Key。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 5) {
                ForEach(0..<28, id: \.self) { index in
                    Capsule()
                        .fill(PogentTheme.accent.opacity(0.8))
                        .frame(width: 3, height: 12 + CGFloat(abs(sin(Double(index) * 0.7))) * 40 * level)
                }
            }
            .frame(height: 60)

            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(PogentTheme.accent)
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
