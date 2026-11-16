import SwiftUI

struct ControlView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var snapshot: ScreenSnapshot?
    @State private var pulse = false
    @State private var selectedElement: Int?

    var body: some View {
        ZStack {
            PogentTheme.background
            ScrollView {
                VStack(spacing: 16) {
                    header
                    mirror
                    controlBar
                    routinesCard
                    boundaryCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .task { await refresh() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("操控手机")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("读屏 → 决定 → 点按 → 再核对。每一步都在你眼前。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(PogentTheme.accent).frame(width: 6, height: 6)
                Text("原生服务")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PogentTheme.accent)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(PogentTheme.accent.opacity(0.12), in: Capsule())
        }
    }

    // MARK: 镜像

    private var mirror: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(PogentTheme.rose).frame(width: 6, height: 6)
                Text("Automation Running")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("同时按住两个音量键可停止")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.35))

            ZStack {
                LinearGradient(colors: [Color(hex: 0x101018), Color(hex: 0x0A0A10)],
                               startPoint: .top, endPoint: .bottom)

                VStack(spacing: 0) {
                    // 假 App 顶栏
                    HStack {
                        Circle().fill(Color.white.opacity(0.10)).frame(width: 28, height: 28)
                            .overlay(Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)))
                        Text(snapshot?.appName ?? "等待读屏")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if let snapshot {
                        elementList(snapshot)
                    } else {
                        ProgressView().tint(PogentTheme.accent).padding(40)
                    }

                    Spacer(minLength: 0)
                }
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if app.control.isRunning {
                    Text("执行中")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(PogentTheme.amber, in: Capsule())
                        .foregroundStyle(PogentTheme.ink)
                        .padding(8)
                }
            }
        }
        .glassCard(cornerRadius: 20, stroke: PogentTheme.accent.opacity(0.25))
    }

    private func elementList(_ snapshot: ScreenSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(snapshot.elements.filter { $0.id != 1 }) { element in
                    Button {
                        selectedElement = element.id
                    } label: {
                        HStack(spacing: 8) {
                            Text("#\(element.id)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(element.label.isEmpty ? element.role : element.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                if let value = element.value {
                                    Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if element.isSecure {
                                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(PogentTheme.rose)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedElement == element.id
                                      ? PogentTheme.accent.opacity(0.16)
                                      : Color.white.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(selectedElement == element.id ? PogentTheme.accent.opacity(0.6) : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            controlButton("主屏", "house.fill") { Task { await perform(.home) } }
            controlButton("返回", "chevron.left") { Task { await perform(.back) } }
            controlButton("读屏", "eye.fill") { Task { await refresh() } }
            controlButton("停止", "stop.fill", tint: PogentTheme.rose) { app.runtime.stop() }
        }
    }

    private func controlButton(_ title: String, _ icon: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .glassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: 例程

    private var routinesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("例程").font(.system(size: 15, weight: .semibold))
                Text("\(app.routines.routines.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "record.circle").font(.system(size: 13)).foregroundStyle(PogentTheme.rose)
            }

            if app.routines.routines.isEmpty {
                Text("跑过一次界面操作后，这里会出现可重放的例程。下次一句话就能重放，参数可以换。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(app.routines.routines) { routine in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(PogentTheme.violet)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(routine.name).font(.system(size: 12, weight: .medium))
                            Text("\(routine.actions.count) 步 · 跑过 \(routine.runs) 次")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("重放") {}
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.bordered)
                            .tint(PogentTheme.violet)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    private var boundaryCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("安全边界", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PogentTheme.accent)

            boundaryRow("付款、删除、Wallet 一定问你", "creditcard")
            boundaryRow("密码和验证码永远留给你自己", "key.fill")
            boundaryRow("锁屏时只能执行有限操作", "lock.iphone")
            boundaryRow("每一步都记进审计账本，可回放", "clock.arrow.circlepath")
        }
        .padding(14)
        .glassCard(cornerRadius: 18)
    }

    private func boundaryRow(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 16)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: 动作

    private func refresh() async {
        do {
            try await app.control.beginTask()
            snapshot = try await app.control.look(full: true)
        } catch {
            // 演示环境没有系统服务时保持空态。
        }
    }

    private func perform(_ action: ControlAction) async {
        do {
            let (newSnapshot, _) = try await app.control.perform([action])
            snapshot = newSnapshot
        } catch {
        }
    }
}
