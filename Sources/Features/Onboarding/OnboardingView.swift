import SwiftUI

struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var page = 0

    var body: some View {
        ZStack {
            PogentTheme.background

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    hero.tag(0)
                    enginePage.tag(1)
                    boundaryPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: 14) {
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule()
                                .fill(index == page ? PogentTheme.accent : Color.white.opacity(0.15))
                                .frame(width: index == page ? 20 : 6, height: 6)
                                .animation(.snappy, value: page)
                        }
                    }

                    Button {
                        if page < 2 {
                            withAnimation { page += 1 }
                        } else {
                            app.hasCompletedOnboarding = true
                        }
                    } label: {
                        Text(page < 2 ? "继续" : "开始使用")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(PogentTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .foregroundStyle(PogentTheme.ink)
                    }
                    .padding(.horizontal, 28)
                }
                .padding(.bottom, 26)
            }
        }
    }

    // MARK: 第一页

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [PogentTheme.accent, PogentTheme.violet],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                    .shadow(color: PogentTheme.accent.opacity(0.4), radius: 30, y: 10)
                Text("P")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(PogentTheme.ink)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("pogent")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("口袋里的全能手机智能体")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(PogentTheme.accent)

                Text("把 agent 引擎装进手机，再让它真的会用你的手机：读屏、点按、跑命令、调系统接口。\n能走接口就不点界面，点界面每一步都看得见。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            HStack(spacing: 8) {
                pill("iOS 27", "iphone")
                pill("本机运行", "cpu")
                pill("全程审计", "checkmark.shield")
            }

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: 第二页

    private var enginePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 10)

            Text("两个项目，一条流水线")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("pogent 把 Poki 的「会操作手机」和 Fish Pocket 的「引擎就在 App 里」合成一个东西。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                mergedRow("操控层", "来自 Poki", "look / do：读元素树、点按、输入、滑动、例程重放。", PogentTheme.amber)
                mergedRow("引擎层", "来自 Fish Pocket", "Node 24 / Python 3.15 / Git / FFmpeg，本机跑，不连电脑。", PogentTheme.violet)
                mergedRow("新的路由", "pogent", "同一件事先问系统接口，再问终端，最后才点界面。", PogentTheme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("不再需要的准备步骤", systemImage: "checkmark.seal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PogentTheme.accent)
                Text("不用电脑装、不用开发者模式、不用 VPN 回环、不用每 7 天重签、不用侧载 iCTRL。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .glassCard(cornerRadius: 14)

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: 第三页

    private var boundaryPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 10)

            Text("先划清边界")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("它会在你真在用的 App 里做事。屏幕内容只在执行时发给你选的模型，会话和工作区留在设备上。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                boundary("付款、删除、Wallet", "一定先问你，任何策略都不能自动放行。", "creditcard")
                boundary("密码、验证码、人机验证", "永远留给你本人，agent 会停下来交接。", "key.fill")
                boundary("每一屏、每一次点按", "进审计账本，可按时间回放。", "clock.arrow.circlepath")
                boundary("锁屏状态", "只允许有限操作，不会偷偷解锁。", "lock.iphone")
            }

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: 组件

    private func pill(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: Capsule())
        .foregroundStyle(.secondary)
    }

    private func mergedRow(_ title: String, _ from: String, _ detail: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color.opacity(0.18)).frame(width: 30, height: 30)
                .overlay(Circle().fill(color).frame(width: 6, height: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(from).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }

    private func boundary(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PogentTheme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
