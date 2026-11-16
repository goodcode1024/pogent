import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        ZStack {
            PogentTheme.background
            if app.hasCompletedOnboarding {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .tint(PogentTheme.accent)
        .animation(.smooth(duration: 0.35), value: app.hasCompletedOnboarding)
    }
}

enum MainTab: Hashable {
    case chat, capabilities, control, workbench, bots, settings
}

struct MainTabView: View {
    @State private var selection: MainTab = .chat

    var body: some View {
        TabView(selection: $selection) {
            Tab("对话", systemImage: "bubble.left.and.bubble.right.fill", value: MainTab.chat) {
                ChatView()
            }
            Tab("能力", systemImage: "square.grid.2x2.fill", value: MainTab.capabilities) {
                CapabilityView()
            }
            Tab("操控", systemImage: "rectangle.on.rectangle.angled", value: MainTab.control) {
                ControlView()
            }
            Tab("工作台", systemImage: "terminal.fill", value: MainTab.workbench) {
                WorkbenchView()
            }
            Tab("Bot", systemImage: "person.3.fill", value: MainTab.bots) {
                BotsView()
            }
            Tab("设置", systemImage: "slider.horizontal.3", value: MainTab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
