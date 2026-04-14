import SwiftUI

@main
struct HandoffApp: App {
    @StateObject private var configStore = ConfigStore.shared
    /// Hoisted to app root so SwiftUI view re-creation can never cause the
    /// TailscaleManager to be released. (Per codex: avoid SwiftUI identity churn
    /// as a possible cause of TailscaleNode.deinit firing prematurely.)
    @StateObject private var tailscale = TailscaleManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configStore)
                .environmentObject(tailscale)
        }
    }
}
