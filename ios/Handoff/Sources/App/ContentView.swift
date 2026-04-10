import SwiftUI

/// Root navigation: routes based on pairing state.
struct ContentView: View {
    @EnvironmentObject var configStore: ConfigStore

    enum Route: Hashable {
        case scan
        case sessions
        case terminal(session: String, window: Int)
    }

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if configStore.isPaired {
                    SessionsView(path: $path)
                } else {
                    WelcomeView(path: $path)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .scan:
                    ScanView(path: $path)
                case .sessions:
                    SessionsView(path: $path)
                case .terminal(let session, let window):
                    TerminalView(sessionName: session, windowIndex: window)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
