import SwiftUI
import SwiftData

/// 连接器：GitHub、Notion、Webhook、RSS。
struct ConnectorsView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context

    @State private var showAdd = false
    @State private var kind: ConnectorKind = .github
    @State private var name = ""
    @State private var token = ""
    @State private var endpoint = ""
    @State private var database = ""
    @State private var toast: String?

    var body: some View {
        ZStack {
            PogentTheme.background
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionCard("怎么用", subtitle: "连一次，之后对话里说「看一下 pogent 仓库的 issue」就能直接调。凭证存在钥匙串，不进数据库。", icon: "link") {
                        EmptyView()
                    }

                    if app.connectors.connectors.isEmpty {
                        EmptyHint(icon: "link.badge.plus", title: "还没有连接", detail: "GitHub 用 Personal Access Token；RSS 只要一个地址。")
                    } else {
                        ForEach(app.connectors.connectors) { record in
                            connectorCard(record)
                        }
                    }

                    Button {
                        resetForm()
                        showAdd = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 14))
                            Text("添加连接").font(.system(size: 13, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(PogentTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(PogentTheme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
        }
        .navigationTitle("连接器")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            addSheet
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastView(text: toast).padding(.top, 8)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
    }

    private func connectorCard(_ record: ConnectorRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.kind.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(record.isEnabled ? PogentTheme.accent : .secondary)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.system(size: 14, weight: .medium))
                Text(record.account.isEmpty ? record.kind.title : "\(record.kind.title) · \(record.account)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { record.isEnabled },
                set: { value in
                    record.isEnabled = value
                    try? context.save()
                }
            ))
            .labelsHidden()
            .tint(PogentTheme.accent)

            Button(role: .destructive) {
                app.connectors.remove(record)
                toast = "已断开"
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(PogentTheme.rose)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .glassCard(cornerRadius: 14)
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section("类型") {
                    Picker("服务", selection: $kind) {
                        ForEach(ConnectorKind.allCases, id: \.self) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("名称") {
                    TextField("例如：我的 GitHub", text: $name)
                }

                if kind == .github || kind == .notion || kind == .openaiCompatible {
                    Section(kind.credentialLabel) {
                        SecureField("粘贴到这里", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if kind == .webhook || kind == .rss {
                    Section("地址") {
                        TextField("https://", text: $endpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if kind == .notion {
                    Section("Database ID（可选）") {
                        TextField("32 位十六进制", text: $database)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Text(helpText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var helpText: String {
        switch kind {
        case .github: "到 GitHub → Settings → Developer settings → Personal access tokens 生成，勾 repo 权限就够。"
        case .notion: "在 Notion 创建 Integration，把目标页面分享给它，再复制 Internal Integration Secret。"
        case .webhook: "任何接受 POST JSON 的地址都行，比如你自己的自动化服务。"
        case .rss: "填 RSS / Atom 地址，读的时候不需要凭证。"
        case .openaiCompatible: "这个入口只做凭证保存。模型配置请到「设置 → 模型」。"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (kind == .rss || !endpoint.isEmpty || !token.isEmpty)
    }

    private func save() {
        var config: [String: String] = [:]
        if !endpoint.isEmpty { config["url"] = endpoint }
        if !database.isEmpty { config["database"] = database }

        app.connectors.add(
            kind: kind,
            name: name.trimmingCharacters(in: .whitespaces),
            account: kind == .github ? "token 已保存" : endpoint,
            token: token,
            config: config
        )
        showAdd = false
        toast = "已添加"
    }

    private func resetForm() {
        kind = .github
        name = ""
        token = ""
        endpoint = ""
        database = ""
    }
}
