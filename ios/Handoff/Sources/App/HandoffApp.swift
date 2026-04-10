import SwiftUI

@main
struct HandoffApp: App {
    @StateObject private var configStore = ConfigStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(configStore)
        }
    }
}
