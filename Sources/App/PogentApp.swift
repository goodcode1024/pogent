import SwiftUI

@main
struct PogentApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .modelContainer(environment.container)
                .preferredColorScheme(.dark)
        }
    }
}
