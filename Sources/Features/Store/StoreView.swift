import SwiftUI
import SwiftData

struct StoreView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \PluginRecord.installedAt, order: .reverse) private var installed: [PluginRecord]

    @State private var query = ""
    @State private var installing: String?

    private var filtered: [MarketplaceItem] {
        let items = app.marketplace.items
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        ZStack {
            PogentTheme.background
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    searchField

                    if !installed.isEmpty {
                        installedSection
                    }

                    Text("推荐")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 2)

                    ForEach(filtered) { item in
                        itemRow(item)
                    }

                    footnote
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .task {
            if app.marketplace.items.isEmpty { await app.marketplace.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("插件市场")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("纯 JS 插件，装了就能用。危险命令还能被安全网拦下。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.tertiary)
            TextField("搜插件、能力、标签", text: $query)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCard(cornerRadius: 12)
    }

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已安装").font(.system(size: 15, weight: .semibold))
            ForEach(installed) { plugin in
                HStack(spacing: 10) {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(PogentTheme.violet)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plugin.name).font(.system(size: 12, weight: .medium))
                        Text("v\(plugin.version) · \(plugin.source)").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { plugin.isEnabled },
                        set: { plugin.isEnabled = $0; try? context.save() }
                    ))
                    .labelsHidden()
                    .tint(PogentTheme.accent)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    private func itemRow(_ item: MarketplaceItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [PogentTheme.violet.opacity(0.5), PogentTheme.accent.opacity(0.35)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 42, height: 42)
                    Text(String(item.name.prefix(1)).uppercased())
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name).font(.system(size: 14, weight: .semibold))
                        Text("v\(item.version)").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Text(item.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(item.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.white.opacity(0.06), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Text("\(item.downloads) 次安装")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack {
                Spacer()
                Button {
                    install(item)
                } label: {
                    Text(installed.contains { $0.name == item.name } ? "已安装" : (installing == item.id ? "安装中…" : "安装"))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            installed.contains { $0.name == item.name } ? Color.white.opacity(0.08) : PogentTheme.accent,
                            in: Capsule()
                        )
                        .foregroundStyle(installed.contains { $0.name == item.name } ? Color.secondary : PogentTheme.ink)
                }
                .disabled(installed.contains { $0.name == item.name } || installing == item.id)
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    private var footnote: some View {
        Text("插件跑在 JavaScriptCore 里，没有文件系统和网络直通。需要更高权限的能力会走 pogent 自己的审批。")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
    }

    private func install(_ item: MarketplaceItem) {
        installing = item.id
        Task {
            defer { installing = nil }
            let manifest = PluginManifest(
                name: item.name,
                version: item.version,
                summary: item.summary,
                author: item.author,
                entry: "index.js",
                permissions: [],
                tools: []
            )
            let installer = PluginInstaller(workspace: app.workspaceURL, runtime: app.plugins)
            _ = try? installer.install(manifest: manifest, source: item.source, context: context)
        }
    }
}
