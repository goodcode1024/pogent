import SwiftUI
import SwiftData

struct BotsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newPersona = ""

    private var bots: [BotProfile] { app.bots.bots }

    var body: some View {
        ZStack {
            PogentTheme.background
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    teamStrip
                    roomsCard
                    scheduleCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showCreate) { createSheet }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Bot 团队")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("每个 Bot 有自己的形象、记忆和工作目录。可以私聊，也可以拉群。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                showCreate = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(PogentTheme.ink)
                    .padding(9)
                    .background(PogentTheme.accent, in: Circle())
            }
        }
    }

    private var teamStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(bots) { bot in
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: UInt32(bot.colorHex.dropFirst(), radix: 16) ?? 0x5EEAD4).opacity(0.18))
                                .frame(width: 54, height: 54)
                            Image(systemName: bot.symbol)
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Color(hex: UInt32(bot.colorHex.dropFirst(), radix: 16) ?? 0x5EEAD4))
                            if app.bots.runningBotID == bot.id {
                                Circle()
                                    .stroke(PogentTheme.accent, lineWidth: 2)
                                    .frame(width: 54, height: 54)
                            }
                        }
                        Text(bot.name).font(.system(size: 11, weight: .medium))
                        Text(app.bots.runningBotID == bot.id ? "干活中" : "空闲")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 66)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var roomsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("群聊").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(app.bots.rooms.count) 个").font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            if app.bots.rooms.isEmpty {
                Text("还没有群。把两三个 Bot 拉在一起，一句话让它们各给一版方案。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ForEach(app.bots.rooms) { room in
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(PogentTheme.violet.opacity(0.15))
                            .frame(width: 34, height: 34)
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(PogentTheme.violet)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(room.title).font(.system(size: 13, weight: .medium))
                        Text("\(room.botIDs.count) 个成员").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
            }

            Button {
                let room = app.bots.createRoom(title: "选题会", botIDs: bots.prefix(3).map(\.id))
                if let first = app.bootstrapConversation() as Conversation? {
                    Task {
                        await app.bots.dispatchToRoom("各自给一个本周值得做的选题，一句话理由。", room: room, conversation: first, modelContext: context)
                    }
                }
            } label: {
                Label("拉个群试试", systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(PogentTheme.violet)
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("定时开工", systemImage: "clock.badge.checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PogentTheme.amber)

            Text("设好时间，Bot 自己开工，结果推到你手机上。锁屏和灵动岛都能看到进度。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if app.scheduler.jobs.isEmpty {
                Button {
                    Task {
                        await app.scheduler.add(.init(botID: bots.first?.id ?? "", prompt: "汇总今天的科技新闻，三条，带链接。",
                                                      hour: 8, minute: 30, weekdays: [2, 3, 4, 5, 6]))
                    }
                } label: {
                    Label("每天早上 8:30 汇总新闻", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(PogentTheme.amber)
            } else {
                ForEach(app.scheduler.jobs) { job in
                    HStack {
                        Text(String(format: "%02d:%02d", job.hour, job.minute))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text(job.prompt).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            app.scheduler.remove(job.id)
                        } label: {
                            Image(systemName: "xmark.circle").font(.system(size: 12))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    private var createSheet: some View {
        NavigationStack {
            Form {
                Section("名字") {
                    TextField("例如 查资料", text: $newName)
                }
                Section("人设") {
                    TextField("它该怎么说话、该注意什么", text: $newPersona, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("新建 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let bot = app.bots.create(
                            name: newName.isEmpty ? "新 Bot" : newName,
                            symbol: "sparkle",
                            colorHex: "#5EEAD4",
                            persona: newPersona
                        )
                        if let conversation = app.bootstrapConversation() as Conversation? {
                            context.insert(Conversation(title: bot.name, kind: .bot, botID: bot.id))
                            try? context.save()
                        }
                        newName = ""
                        newPersona = ""
                        showCreate = false
                    }
                }
            }
        }
    }
}
