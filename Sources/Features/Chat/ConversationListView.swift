import SwiftUI
import SwiftData

/// 会话列表：搜索、置顶、归档、导出、删除。
struct ConversationListView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var search = ""
    @State private var showArchived = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var exporting: Conversation?

    var onSelect: (Conversation) -> Void

    private var visible: [Conversation] {
        conversations.filter { conversation in
            guard conversation.isArchived == showArchived else { return false }
            guard !search.isEmpty else { return true }
            return conversation.title.localizedCaseInsensitiveContains(search)
                || conversation.lastText.localizedCaseInsensitiveContains(search)
        }
        .sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                        TextField("搜索标题或内容", text: $search)
                            .font(.system(size: 13))
                    }
                }

                Section {
                    if visible.isEmpty {
                        Text(search.isEmpty ? (showArchived ? "没有归档的会话" : "还没有会话") : "没找到")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { conversation in
                        row(conversation)
                    }
                }

                Section {
                    Toggle("显示归档", isOn: $showArchived)
                        .font(.system(size: 12))
                }
            }
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let conversation = Conversation(title: "新对话")
                        context.insert(conversation)
                        try? context.save()
                        onSelect(conversation)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .alert("重命名", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("标题", text: $newTitle)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    renaming?.title = newTitle
                    try? context.save()
                    renaming = nil
                }
            }
            .sheet(item: $exporting) { conversation in
                ShareSheet(items: [export(conversation)])
            }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        Button {
            onSelect(conversation)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if conversation.isPinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(PogentTheme.amber)
                        }
                        Text(conversation.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                    }
                    Text(conversation.lastText.isEmpty ? "空白会话" : conversation.lastText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                context.delete(conversation)
                try? context.save()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                conversation.isPinned.toggle()
                try? context.save()
            } label: {
                Label(conversation.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            .tint(PogentTheme.amber)
        }
        .contextMenu {
            Button(conversation.isPinned ? "取消置顶" : "置顶", systemImage: "pin") {
                conversation.isPinned.toggle()
                try? context.save()
            }
            Button("重命名", systemImage: "pencil") {
                newTitle = conversation.title
                renaming = conversation
            }
            Button(conversation.isArchived ? "取消归档" : "归档", systemImage: "archivebox") {
                conversation.isArchived.toggle()
                try? context.save()
            }
            Button("导出文本", systemImage: "square.and.arrow.up") {
                exporting = conversation
            }
        }
    }

    private func export(_ conversation: Conversation) -> String {
        let messages = ChatMessage.history(for: conversation.id, in: context, limit: 500)
        var lines = ["# \(conversation.title)", ""]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for message in messages {
            let role = message.role == .user ? "我" : "pogent"
            lines.append("**\(role)** · \(formatter.string(from: message.createdAt))")
            lines.append(message.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
