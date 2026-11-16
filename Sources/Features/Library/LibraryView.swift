import SwiftUI
import SwiftData

/// 技能、审计、记忆三合一的库。
struct LibraryView: View {
    enum Tab: String, CaseIterable {
        case skills = "技能"
        case audit = "审计"
        case memory = "记忆"
    }

    @State private var tab: Tab = .skills

    var body: some View {
        ZStack {
            PogentTheme.background
            VStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ScrollView {
                    switch tab {
                    case .skills: SkillsSection()
                    case .audit: AuditSection()
                    case .memory: MemorySection()
                    }
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("库")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MemoryView: View {
    var body: some View {
        ZStack {
            PogentTheme.background
            ScrollView { MemorySection() }
        }
        .navigationTitle("记忆")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 技能

struct SkillsSection: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \SkillRecord.createdAt, order: .reverse) private var skills: [SkillRecord]

    @State private var runningID: String?
    @State private var toast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCard("怎么来的", subtitle: "跑完一个任务后，在对话页右上角点「存为技能」。下次一句话就能重放这一整套步骤。", icon: "wand.and.stars") {
                EmptyView()
            }

            if skills.isEmpty {
                EmptyHint(icon: "square.stack.3d.up", title: "还没有技能", detail: "先让 pogent 完整跑一件事，再把它存下来。")
            } else {
                ForEach(skills) { skill in
                    skillCard(skill)
                }
            }
        }
        .padding(16)
        .overlay(alignment: .top) {
            if let toast {
                ToastView(text: toast).padding(.top, 4)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
    }

    private func skillCard(_ skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(skill.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(stepCount(skill)) 步")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PogentTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(PogentTheme.accent.opacity(0.14), in: Capsule())
            }

            Text(skill.goalTemplate)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Button {
                    run(skill)
                } label: {
                    HStack(spacing: 4) {
                        if runningID == skill.id {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        }
                        Text(runningID == skill.id ? "执行中" : "重放")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(PogentTheme.accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(PogentTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(runningID != nil)

                Button {
                    UIPasteboard.general.string = skill.goalTemplate
                    toast = "已复制目标"
                } label: {
                    Text("复制目标")
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(role: .destructive) {
                    context.delete(skill)
                    try? context.save()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(PogentTheme.rose)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private func stepCount(_ skill: SkillRecord) -> Int {
        guard let data = skill.stepsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = object["steps"] as? [[String: Any]] else { return 0 }
        return steps.count
    }

    private func run(_ skill: SkillRecord) {
        runningID = skill.id
        let conversation = app.bootstrapConversation()
        Task {
            await app.runtime.submit(skill.goalTemplate, conversation: conversation, context: context)
            runningID = nil
            toast = "重放完成，回对话页看结果"
        }
    }
}

// MARK: - 审计

struct AuditSection: View {
    @Environment(AppEnvironment.self) private var app

    @State private var filter: AuditLedger.Entry.Kind?
    @State private var showShare = false
    @State private var search = ""

    private var entries: [AuditLedger.Entry] {
        let all = app.ledger.entries.reversed()
        return all.filter { entry in
            if let filter, entry.kind != filter { return false }
            if search.isEmpty { return true }
            return entry.title.localizedCaseInsensitiveContains(search)
                || entry.detail.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("搜标题或内容", text: $search)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassCard(cornerRadius: 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("全部", active: filter == nil) { filter = nil }
                    chip("工具", active: filter == .toolResult) { filter = .toolResult }
                    chip("审批", active: filter == .approval) { filter = .approval }
                    chip("错误", active: filter == .error) { filter = .error }
                    chip("系统", active: filter == .system) { filter = .system }
                }
            }

            HStack {
                Text("\(entries.count) 条")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    showShare = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 10, weight: .semibold))
                        Text("导出").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(entries.isEmpty)
            }

            if entries.isEmpty {
                EmptyHint(icon: "clock.arrow.circlepath", title: "还没有记录", detail: "每次看屏、点按、跑命令、审批都会写进这本账。")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(300))) { entry in
                        entryRow(entry)
                        if entry.id != entries.prefix(300).last?.id {
                            Divider().overlay(Color.white.opacity(0.05)).padding(.leading, 12)
                        }
                    }
                }
                .glassCard(cornerRadius: 14)
            }
        }
        .padding(16)
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [app.ledger.export()])
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? PogentTheme.accent.opacity(0.18) : Color.white.opacity(0.05), in: Capsule())
                .foregroundStyle(active ? PogentTheme.accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func entryRow(_ entry: AuditLedger.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color(entry.kind))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(entry.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func color(_ kind: AuditLedger.Entry.Kind) -> Color {
        switch kind {
        case .error: PogentTheme.rose
        case .approval: PogentTheme.amber
        case .toolResult, .toolCall: PogentTheme.accent
        case .userMessage: PogentTheme.violet
        default: Color.white.opacity(0.3)
        }
    }
}

// MARK: - 记忆

struct MemorySection: View {
    @Environment(AppEnvironment.self) private var app

    @State private var showAdd = false
    @State private var draft = ""
    @State private var kind: MemoryKind = .fact
    @State private var toast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCard("它记住的事", subtitle: "对话里说「记住……」会自动存进来。只存在这台设备上。", icon: "brain") {
                Button {
                    draft = ""
                    showAdd = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("手动添加").font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(PogentTheme.accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(PogentTheme.accent)
                }
                .buttonStyle(.plain)
            }

            if app.memory.items.isEmpty {
                EmptyHint(icon: "brain.head.profile", title: "还没有记忆", detail: "告诉它「记住我住在杭州」，下次就会带上这条。")
            } else {
                ForEach(MemoryKind.allCases, id: \.self) { kind in
                    let items = app.memory.items.filter { $0.kind == kind }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(kind.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(items) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(item.text)
                                        .font(.system(size: 12))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Button {
                                        app.memory.delete(item)
                                        toast = "已删除"
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                    }
                }

                Button(role: .destructive) {
                    app.memory.clear()
                    toast = "已清空"
                } label: {
                    Text("清空全部记忆")
                        .font(.system(size: 11))
                        .foregroundStyle(PogentTheme.rose)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .alert("添加记忆", isPresented: $showAdd) {
            TextField("例如：我住在杭州，不吃香菜", text: $draft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                app.memory.add(text, kind: kind)
                toast = "已记住"
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(text: toast).padding(.top, 4)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
    }
}
