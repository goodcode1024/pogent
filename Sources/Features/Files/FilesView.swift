import SwiftUI
import QuickLook

/// 工作区文件浏览器：进目录、看文本、看图片、分享、删除。
struct FilesView: View {
    @Environment(AppEnvironment.self) private var app

    @State private var path: String = "."
    @State private var entries: [Entry] = []
    @State private var previewFile: PreviewTarget?
    @State private var showNewFile = false
    @State private var newName = ""
    @State private var toast: String?
    @State private var deleting: Entry?

    struct Entry: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date

        var icon: String {
            if isDirectory { return "folder.fill" }
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "png", "jpg", "jpeg", "heic", "gif", "webp": return "photo.fill"
            case "md", "txt", "log": return "doc.text.fill"
            case "swift", "js", "ts", "py", "sh", "json", "yml", "yaml": return "chevron.left.forwardslash.chevron.right"
            case "pdf": return "doc.richtext.fill"
            case "m4a", "mp3", "wav", "mp4", "mov": return "play.rectangle.fill"
            case "zip", "gz": return "archivebox.fill"
            default: return "doc.fill"
            }
        }
    }

    struct PreviewTarget: Identifiable {
        var id: String { url.absoluteString }
        var url: URL
        var isImage: Bool
    }

    var body: some View {
        ZStack {
            PogentTheme.background
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    pathBar

                    if entries.isEmpty {
                        EmptyHint(
                            icon: "folder",
                            title: "这个目录是空的",
                            detail: "pogent 的工作区在 App 沙箱里。智能体读写文件、跑命令、存截图都在这里。"
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(entries) { entry in
                                row(entry)
                                if entry.id != entries.last?.id {
                                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 44)
                                }
                            }
                        }
                        .glassCard(cornerRadius: 16)
                    }

                    Text("共 \(entries.count) 项 · 路径 \(path)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .navigationTitle("文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新建文本文件", systemImage: "doc.badge.plus") {
                        newName = ""
                        showNewFile = true
                    }
                    Button("刷新", systemImage: "arrow.clockwise") { reload() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { reload() }
        .sheet(item: $previewFile) { target in
            NavigationStack {
                QuickLookPreview(url: target.url)
                    .ignoresSafeArea()
                    .navigationTitle(target.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { previewFile = nil }
                        }
                    }
            }
        }
        .alert("新建文件", isPresented: $showNewFile) {
            TextField("文件名，例如 notes.md", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") { createFile() }
        }
        .alert("删除 \(deleting?.name ?? "")？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let entry = deleting { remove(entry) }
                deleting = nil
            }
        } message: {
            Text("删除后无法恢复。")
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

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                goUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(path == "." ? .tertiary : .secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .disabled(path == ".")

            Text(path == "." ? "工作区" : path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            Text(DeviceInfoTool.gb(totalSize))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(entry.isDirectory ? PogentTheme.amber : PogentTheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle(entry))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("预览", systemImage: "eye") { preview(entry) }
            Button("分享", systemImage: "square.and.arrow.up") { share(entry) }
            Button("删除", systemImage: "trash", role: .destructive) { deleting = entry }
        }
    }

    private func subtitle(_ entry: Entry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let size = entry.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        return "\(size) · \(formatter.string(from: entry.modified))"
    }

    private var totalSize: Int64 {
        entries.reduce(0) { $0 + $1.size }
    }

    private var directory: URL {
        path == "." ? app.workspaceURL : app.workspaceURL.appendingPathComponent(path)
    }

    private func reload() {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        entries = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return Entry(
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? Date()
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func open(_ entry: Entry) {
        if entry.isDirectory {
            path = path == "." ? entry.name : "\(path)/\(entry.name)"
            reload()
        } else {
            preview(entry)
        }
    }

    private func preview(_ entry: Entry) {
        let url = directory.appendingPathComponent(entry.name)
        previewFile = PreviewTarget(url: url, isImage: false)
    }

    private func share(_ entry: Entry) {
        let url = directory.appendingPathComponent(entry.name)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let top = Presentation.topViewController() else { return }
        top.present(controller, animated: true)
    }

    private func goUp() {
        guard path != "." else { return }
        let parts = path.split(separator: "/").dropLast()
        path = parts.isEmpty ? "." : parts.joined(separator: "/")
        reload()
    }

    private func createFile() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let url = directory.appendingPathComponent(name)
        do {
            try "# \(name)\n\n".write(to: url, atomically: true, encoding: .utf8)
            reload()
            toast = "已创建 \(name)"
        } catch {
            toast = "创建失败：\(error.localizedDescription)"
        }
    }

    private func remove(_ entry: Entry) {
        let url = directory.appendingPathComponent(entry.name)
        do {
            try FileManager.default.removeItem(at: url)
            reload()
            toast = "已删除"
        } catch {
            toast = "删除失败：\(error.localizedDescription)"
        }
    }
}
